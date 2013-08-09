module Main where
import OpenAFP
import System.Exit
import Data.Char (isDigit, isAlphaNum)
import Data.List (find)
import qualified Data.ByteString.Char8 as C

main :: IO ()
main = do
    args    <- getArgs
    if null args then error "Usage: afp-tledump file.afp" else do
    let (inFile:_) = args
    cs <- readAFP inFile
    forM_ (filter (~~ _TLE) cs) $ \tle -> do
        let Just (fqn:av:_) = tle_Chunks `applyToChunk` tle
            Just key = t_fqn `applyToChunk` fqn
            Just val = t_av `applyToChunk` av
        putStr (fromAStr key)
        putStr "="
        putStrLn (fromAStr val)
