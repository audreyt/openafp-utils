module Main where
import Text.XHtml
import OpenAFP hiding ((!))
import qualified OpenAFP ((!))
import qualified Data.Set as Set
import qualified Data.ByteString as S
import qualified Data.ByteString.Unsafe as S
import qualified Data.ByteString.Internal as S
import qualified Data.ByteString.Char8 as C
import qualified Data.Text as T
import Data.Text.Encoding.Locale (decodeLocale', encodeLocale')
import System.IO (noNewlineTranslation)

-- The key here is inventing a ConcreteDataView for our data structure.
-- See OpenAFP.Types.View for details.

type Encodings = [String]

data Opts = Opts
    { encodings         :: Encodings
    , inputFile         :: String
    , openOutputHandle  :: IO Handle
    , verbose           :: Bool
    , showHelp          :: IO ()
    } deriving (Typeable)

defaultOpts :: Opts
defaultOpts = Opts
    { encodings         = ["937", "500"]
    , inputFile         = requiredOpt usage "input"
    , openOutputHandle  = return stdout
    , verbose           = False
    , showHelp          = return ()
    }

usage :: String -> IO a
usage = showUsage options showInfo
    where
    showInfo prg = 
        "Usage: " ++ prg ++ " [-e enc,enc...] input.afp > output.html\n" ++
        "( example: " ++ prg ++ " -e 437,947 big5.afp > output.html)"

options :: [OptDescr (Opts -> Opts)]
options =
    [ reqArg "e" ["encodings"]      "ENC,ENC..."    "Text encodings (default: 937,500)"
        (\s o -> o { encodings          = splitComma s })
    , reqArg "i" ["input"]          "FILE"          "Input AFP file"
        (\s o -> o { inputFile          = s })
    , reqArg "o" ["output"]         "FILE"          "Output HTML file"
        (\s o -> o { openOutputHandle   = openFile s WriteMode })
    , noArg  "h" ["help"]                           "Show help"
        (\o   -> o { showHelp           = usage "" })
    ]

splitComma :: String -> [String]
splitComma "" =  []
splitComma s = l : case s' of
    []      -> []
    (_:s'') -> splitComma s''
    where
    (l, s') = break (== ',') s


getOpts :: IO Opts
getOpts = do
    args <- getArgs
    (optsIO, rest, errs) <- return . getOpt Permute options $ procArgs args
    return $ foldl (flip ($)) defaultOpts optsIO
    where
    procArgs xs
	| null xs	    = ["-h"]
	| even $ length xs  = xs
	| otherwise	    = init xs ++ ["-i", last xs]

run :: IO ()
run = withArgs (words "-e 937,500 -i ln-1.afp -o x.html") main

main :: IO ()
main = do
    opts    <- getOpts
    let input = inputFile opts
    cs      <- readAFP input
    fh      <- openOutputHandle opts
    writeIORef encsRef $ encodings opts
    let put = hPutStr fh
    put "<?xml version=\"1.0\"?>"
    put "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">"
    put "<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en\" xml:lang=\"en\">"
    put $ htmlPage input
    put "<ol class=\"top\">"
    mapM_ (hPutStrLn fh . (`withChunk` (showHtmlFragment . recHtml . recView))) cs
    put "</ol></body></html>"
    hClose fh

{-# NOINLINE encs #-}
encs :: Encodings
encs = unsafePerformIO (readIORef encsRef)

{-# NOINLINE encsRef #-}
encsRef :: IORef Encodings
encsRef = unsafePerformIO (newIORef (error "oops"))

htmlPage :: String -> String
htmlPage title = showHtmlFragment
    [ header <<
        [ meta !
            [ httpequiv "Content-Type"
            , content "text/html; charset=UTF-8"
            ]
        , thetitle << ("AFP Dump - " ++ title)
        , style !
            [thetype "text/css"
            ] << styles
        ]
    , h1 << title
    ]

styles :: String
styles = unlines [
    "body { background: #e0e0e0; font-family: times new roman, times; margin-left: 20px }",
    "h1 { font-family: times new roman, times }",
    "span { font-family: andale mono, courier }",
    "ol { border-left: 1px dotted black }",
    "ol.top { border-left: none }",
    "table { font-size: small; border: 0px; border-left: 1px dotted black; padding-left: 6pt; width: 100% }",
    "td.label { background: #d0d0d0; font-family: arial unicode ms, helvetica }",
    "td.item { background: white; width: 100%; font-family: arial unicode ms, helvetica }",
    "div { text-decoration: underline; background: #e0e0ff; font-family: arial unicode ms, helvetica }"
    ]

recHtml :: ViewRecord -> Html
recHtml (ViewRecord t fs)
    | t == typeOf _PTX_TRN
    , (_ : ViewField _ (ViewNStr _ nstr) : []) <- fs
    = li << (typeHtml t +++ ptxHtml (map N1 (S.unpack nstr)))
    | otherwise
    = li << (typeHtml t +++ fieldsHtml fs)

{-# NOINLINE _TypeHtmlCache #-}
_TypeHtmlCache :: HashTable RecordType Html
_TypeHtmlCache = unsafePerformIO hashCreate

{-# NOINLINE _FontToEncoding #-}
_FontToEncoding :: HashTable N1 Encoding
_FontToEncoding = unsafePerformIO hashCreate

typeHtml :: RecordType -> Html
typeHtml t = unsafePerformIO $ do
    rv <- hashLookup _TypeHtmlCache t
    case rv of 
        Just html   -> return html
        _           -> do
            let html = typeHtml' t
            hashInsert _TypeHtmlCache t html
            return html

typeHtml' :: RecordType -> Html
typeHtml' t = thediv << (typeStr +++ primHtml " &mdash; " +++ typeDesc)
    where
    typeStr = bold << reverse (takeWhile (/= '.') (reverse typeRepr))
    typeDesc = stringToHtml $ descLookup (mkChunkType t)
    typeRepr = show t

ptxHtml :: [N1] -> [Html]
ptxHtml nstr = [table << textHtml]
    where
    textHtml = textLine ++ [ nstrLine ]
    textLine = [ fieldHtml (ViewField (C.pack $ "(" ++ n ++ ")") (ViewString (typeOf ()) txt)) | (n, txt) <- texts nstr ]
    nstrLine = tr << td ! [colspan 2] << thespan << nstrHtml nstr

texts :: [N1] -> [(String, ByteString)]
texts nstr = maybeToList $ msum [ maybe Nothing (Just . ((,) cp)) $! conv (codeName cp) | cp <- encs ]
    where
    {-
    conv c@"ibm-937"
        | (even $ length nstr)  = convert' c "UTF-8" (packNStr $ toNStr (0x0E : nstr))
        | otherwise             = Nothing
    -}
    conv c = convert' c "UTF-8" (packNStr $ toNStr nstr)
    codeName c
        | isJust $ find (not . isDigit) c   = c
        | otherwise                         = "ibm-" ++ c

{-# NOINLINE convert' #-}
convert' "ibm-835" to str = convert' "CP950" to (packWith convert835to950 str)
convert' "ibm-939" to str = convert' "CP932" to (packWith convert939to932 str)
convert' "ibm-947" to str = convert' "CP950" to str
convert' "ibm-950" to str = convert' "CP950" to str
convert' "ibm-937" to str = convert' "CP950" to $ S.map ((OpenAFP.!) ebc2ascIsPrintW8) str
convert' "ibm-500" to str = convert' "ascii" to $ S.map ((OpenAFP.!) ebc2ascIsPrintW8) str
convert' "ibm-37" to str = convert' "ascii" to $ S.map ((OpenAFP.!) ebc2ascIsPrintW8) str
convert' from to str = case unsafePerformIO doConvert of
    Left ioerr -> Nothing
    Right str -> Just $! str
    where
    doConvert = tryIOError $ do
        encFrom <- mkTextEncoding from
        encTo   <- mkTextEncoding to
        txt     <- decodeLocale' encFrom noNewlineTranslation str
        encodeLocale' encTo noNewlineTranslation txt

{-# INLINE packWith #-}
packWith :: (Int -> Int) -> ByteString -> ByteString
packWith f buf = unsafePerformIO $ S.unsafeUseAsCStringLen buf $ \(src, len) -> S.create len $ \target -> do
    let s = castPtr src
    let t = castPtr target
    forM_ [0..(len `div` 2)-1] $ \i -> do
        hi  <- peekByteOff s (i*2)       :: IO Word8
        lo  <- peekByteOff s (i*2+1)     :: IO Word8
        let ch         = f (fromEnum hi * 256 + fromEnum lo)
            (hi', lo') = ch `divMod` 256
        pokeByteOff t (i*2)   (toEnum hi' :: Word8)
        pokeByteOff t (i*2+1) (toEnum lo' :: Word8)

fieldsHtml :: [ViewField] -> [Html]
fieldsHtml fs = [table << fsHtml] ++ membersHtml
    where
    fsHtml = [ map fieldHtml fields ]
    membersHtml = chunksHtml $ csHtml ++ dataHtml
    csHtml = [ c | ViewField _ (ViewChunks t c) <- fs ]
    dataHtml = [ c | ViewField _ (ViewData t c) <- fs ]
    fields = sortBy fieldOrder [ v | v@(ViewField str _) <- fs, strOk str ]
    fieldOrder (ViewField a _) (ViewField b _)
        | S.null a  = GT
        | S.null b  = LT
        | otherwise = compare a b
    strOk str
        | S.null str        = True
        | '_' <- C.head str = False
        | otherwise         = Set.notMember str blobFields


blobFields :: Set.Set FieldLabel
blobFields = Set.fromList $ map C.pack
    [ "Data", "EscapeSequence", "Chunks", "ControlCode", "CC", "FlagByte", "Type", "SubType" ]

chunksHtml :: [[ViewRecord]] -> [Html]
chunksHtml [] = []
chunksHtml (cs:_) = [olist << map recHtml cs]

fieldHtml (ViewField str content)
    | S.null str = case content of
        ViewNStr _ nstr | S.null nstr -> noHtml
        _             -> tr << td ! [colspan 2, theclass "item"] << contentHtml content
    | otherwise = tr << [td ! [theclass "label"] << C.unpack str, td ! [theclass "item"] << contentHtml content ]

contentHtml :: ViewContent -> Html
contentHtml x = case x of
    ViewNumber _ n -> stringToHtml $ show n
    ViewString _ s -> stringToHtml $ ['"'] ++ unpackUTF8 s ++ ['"']
    ViewNStr  _ cs -> thespan << nstrHtml (map N1 (S.unpack cs))
    _              -> error (show x)

unpackUTF8 :: ByteString -> String
unpackUTF8 buf = unsafePerformIO $ do
    enc <- mkTextEncoding "UTF-8"
    fmap T.unpack $ decodeLocale' enc noNewlineTranslation buf

nstrHtml :: [N1] -> String
nstrHtml nstr
    | length nstr >= 80 = nstrStr nstr ++ "..."
    | otherwise         = nstrStr nstr
    where
    nstrStr :: [N1] -> String
    nstrStr = concatMap ((' ':) . show)
