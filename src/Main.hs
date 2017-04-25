{-# LANGUAGE TupleSections, RecordWildCards, ScopedTypeVariables #-}

module Main(main) where

import Hi
import Cabal
import Stack
import Util
import Data.List.Extra
import Data.Maybe
import Data.Functor
import Data.IORef
import Data.Tuple.Extra
import Control.Monad
import System.Exit
import System.IO.Extra
import qualified Data.HashMap.Strict as Map
import qualified Data.HashSet as Set
import System.Directory.Extra
import System.FilePath
import System.Environment
import System.Process
import Prelude


main :: IO ()
main = do
    args <- getArgs
    if "--test" `elem` args then
        runTest ("--update" `elem` args)
    else do
        errs <- fmap sum $ mapM weedDirectory $ if null args then ["."] else args
        when (errs > 0) exitFailure


runTest :: Bool -> IO ()
runTest update = do
    _ <- readCreateProcess (proc "stack" ["build"]){cwd=Just "test"} ""
    let f = filter (/= "") . lines
    expect <- readFile' "test/output.txt"
    got <- fmap fst $ captureOutput $ weedDirectory "test"
    if f expect == f got then putStrLn "Test passed" else do
        diff <- findExecutable "diff"
        if update then do
            writeFileBinary "test/output.txt" got
            putStrLn "UPDATED output.txt due to --update"
         else if isNothing diff then
            putStr $ unlines $ map ("- " ++) (lines expect) ++ map ("+ " ++) (lines got)
         else
            withTempDir $ \dir -> do
                writeFile (dir </> "old.txt") expect
                writeFile (dir </> "new.txt") got
                callProcess "diff" ["-u3",dir </> "old.txt", dir </> "new.txt"]
        exitFailure

listLines = map ("  "++) . sort

weedDirectory :: FilePath -> IO Int
weedDirectory dir = do
    file <- do b <- doesDirectoryExist dir; return $ if b then dir </> "stack.yaml" else dir
    Stack{..} <- parseStack file
    cabals <- forM stackPackages $ \x -> do
        file <- selectCabalFile $ dir </> x
        (file,) <$> parseCabal file

    -- put it in an IORef so harder to "lose" error reports
    errCount <- newIORef 0
    let reportErrors xs = do
            modifyIORef errCount (+ length (filter (" " `isPrefixOf`) xs))
            -- I tried stderr, but the output gets interleaved
            putStr $ unlines xs

    forM_ cabals $ \(cabalFile, cabal@Cabal{..}) -> do
        let distDir = takeDirectory cabalFile </> stackDistDir
        (fileToKey, keyToHi) <- hiParseDirectory distDir
        putStrLn $ "= Weeding " ++ cabalName ++ " ="
        cabalSections <- return $ map (id &&& selectHiFiles fileToKey) cabalSections

        -- detect files used in more than one group
        let reused :: [(HiKey, ModuleName, [CabalSectionType])] =
                filter ((> 1) . length . thd3) $
                map (\((a,b),c) -> (a,b,c)) $
                groupSort
                [((x, hiModuleName $ keyToHi Map.! x), cabalSectionType sect) | (sect, (x1,x2)) <- cabalSections, x <- x1++x2]
        if null reused then
            putStrLn "No modules reused between components"
        else
            reportErrors $ concat
                [ ("Reused between " ++ intercalate ", " (map show pkgs)) : listLines mods
                | (pkgs, mods) <- groupSort $ map (thd3 &&& snd3) reused]
        let shared = Set.fromList $ map fst3 reused
        putStrLn ""

        generalBad <- forM cabalSections $ \(CabalSection{..}, (external, internal)) -> do
            putStrLn $ "== Weeding " ++ cabalName ++ ", " ++ show cabalSectionType ++ " =="
            shared <- return $ Set.fromList [hiModuleName $ keyToHi Map.! x | x <- external ++ internal, x `Set.member` shared]
            shared <- return Set.empty
            (external, internal) <- return $ both (map (keyToHi Map.!)) (external, internal)

            -- first go looking for packages that are not used
            let bad = Set.fromList cabalPackages `Set.difference` Set.unions (map hiImportPackage $ external ++ internal)
            if Set.null bad then
                putStrLn "No weeds in the build-depends field"
            else
                reportErrors $ "Redundant build-depends entries:" : listLines (Set.toList bad)

            -- now look for modules which are imported but not in the other-modules list
            let imports = Map.fromList [(hiModuleName, Set.map identModule hiImportIdent) | Hi{..} <- external ++ internal]
            let missing = Set.filter (not . isPathsModule) $
                          Set.unions (Map.elems imports) `Set.difference`
                          Set.fromList (Map.keys imports)
            let excessive = Set.fromList (map hiModuleName internal) `Set.difference`
                            reachable (\k -> maybe [] Set.toList $ Map.lookup k imports) (map hiModuleName external)
            if Set.null missing && Set.null excessive then
                putStrLn "No weeds in the other-modules field"
            else do
                unless (Set.null missing) $
                    reportErrors $ "Missing other-modules entries:" : listLines (Set.toList missing)
                unless (Set.null excessive) $
                    reportErrors $ "Excessive other-modules entries:" : listLines (Set.toList excessive)


            -- now see which things are defined in and exported out of the internals, but not used elsewhere or external
            let publicAPI = Set.unions $ map hiExportIdentUnsupported external
            let visibleInternals = Set.unions [Set.filter ((==) hiModuleName . identModule) $ hiExportIdentUnsupported hi | hi@Hi{..} <- internal]
            -- if someone imports and exports something assume that isn't also a use (find some redundant warnings)
            let usedAnywhere = Set.unions [hiImportIdent `Set.difference` hiExportIdent | Hi{..} <- external ++ internal]
            let bad = visibleInternals `Set.difference` Set.union publicAPI usedAnywhere
            let badPerModule = groupSort [(m,i) | Ident m i <- Set.toList bad]
            let (generalBad, myBad) = partition (flip Set.member shared . fst) badPerModule
            if null myBad then
                putStrLn "No weeds in the module exports"
            else
                reportErrors $ concat
                    [ ("Weeds exported from " ++ m) : listLines is | (m, is) <- myBad]
            putStrLn ""
            return (cabalSectionType, generalBad)

        return ()

    readIORef errCount
