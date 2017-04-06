{-# LANGUAGE TupleSections #-}

module Util(parseHanging, stripPrefixLower) where

import Data.Char
import Data.List.Extra
import Data.Tuple.Extra


parseHanging :: [String] -> [(String, [String])]
parseHanging = repeatedly (\(x:xs) -> first (\a -> (x, unindent a)) $ span (\x -> null x || " " `isPrefixOf` x) xs)


stripPrefixLower :: String -> String -> Maybe String
stripPrefixLower a b
    | lower a `isPrefixOf` lower b = Just $ drop (length a) b
    | otherwise = Nothing


unindent :: [String] -> [String]
unindent xs = map (drop n) xs
    where
        n = minimum $ top : map f xs
        f x = let (a,b) = span isSpace x in if null b then top else length a
        top = 1000
