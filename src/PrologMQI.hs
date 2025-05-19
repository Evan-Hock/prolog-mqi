{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumericUnderscores #-}

module PrologMQI
    -- The Prolog server type
    ( MQI


    -- The Prolog thread type
    , PrologThread(..)


    -- Prolog value type
    , PrologValue(..)


    -- Prolog query result
    , QueryResult(..)


    -- Prolog exceptions
    , PrologLaunchException(..)
    , PrologRecvDecodingException(..)
    , PrologConnectionFailedException(..)
    , PrologQueryTimeoutException(..)
    , PrologNoQueryException(..)
    , PrologQueryCancelledException(..)
    , PrologResultNotAvailableException(..)
    , SomePrologException


    -- Typeclass of Prolog exceptions
    , PrologRuntimeException(..)


    -- Starting and stopping the Prolog server
    , startProlog, stopProlog, withProlog

    -- Starting and stopping Prolog threads
    , startPrologThread

    -- Making queries
    , query, queryTimeout
    ) where


import Control.Concurrent
import qualified Control.Exception as E
import Control.Monad
import qualified Data.Aeson as J
import Data.Aeson (FromJSON(..), ToJSON(..), (.=), (.:))
import qualified Data.Aeson.Types as JT
import qualified Data.ByteString.Char8 as C
import Data.ByteString.Char8 (ByteString)
import Data.Char
import qualified Data.HashMap.Strict as HM
import Data.HashMap.Strict (HashMap)
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Network.Socket
import Network.Socket.ByteString
import qualified System.IO as IO
import System.Process


data MQI = MQI
    { mqiStdout :: IO.Handle
    , mqiStderr :: IO.Handle
    , mqiProcessHandle :: ProcessHandle
    , mqiPort :: String
    , mqiPassword :: Text
    , mqiConnectionFailed :: Bool
    }


newtype PrologRecvDecodingException = PrologRecvDecodingException ByteString
    deriving (Show)

instance E.Exception PrologRecvDecodingException


newtype PrologLaunchException = PrologLaunchException String
    deriving (Show)

instance E.Exception PrologLaunchException


newtype PrologConnectionFailedException = PrologConnectionFailedException PrologValue
    deriving (Show)

instance E.Exception PrologConnectionFailedException


newtype PrologQueryTimeoutException = PrologQueryTimeoutException PrologValue
    deriving (Show)

instance E.Exception PrologQueryTimeoutException


newtype PrologNoQueryException = PrologNoQueryException PrologValue
    deriving (Show)

instance E.Exception PrologNoQueryException


newtype PrologQueryCancelledException = PrologQueryCancelledException PrologValue
    deriving (Show)

instance E.Exception PrologQueryCancelledException


newtype PrologResultNotAvailableException = PrologResultNotAvailableException PrologValue
    deriving (Show)

instance E.Exception PrologResultNotAvailableException


newtype SomePrologException = SomePrologException PrologValue
    deriving (Show)

instance E.Exception SomePrologException


class PrologRuntimeException e where
    toSomePrologException :: e -> SomePrologException
    fromSomePrologException :: SomePrologException -> e


instance PrologRuntimeException SomePrologException where
    toSomePrologException = id
    fromSomePrologException = id


instance PrologRuntimeException PrologConnectionFailedException where
    toSomePrologException (PrologConnectionFailedException v) = SomePrologException v
    fromSomePrologException (SomePrologException v) = PrologConnectionFailedException v


instance PrologRuntimeException PrologQueryTimeoutException where
    toSomePrologException (PrologQueryTimeoutException v) = SomePrologException v
    fromSomePrologException (SomePrologException v) = PrologQueryTimeoutException v


instance PrologRuntimeException PrologNoQueryException where
    toSomePrologException (PrologNoQueryException v) = SomePrologException v
    fromSomePrologException (SomePrologException v) = PrologNoQueryException v


instance PrologRuntimeException PrologQueryCancelledException where
    toSomePrologException (PrologQueryCancelledException v) = SomePrologException v
    fromSomePrologException (SomePrologException v) = PrologQueryCancelledException v


instance PrologRuntimeException PrologResultNotAvailableException where
    toSomePrologException (PrologResultNotAvailableException v) = SomePrologException v
    fromSomePrologException (SomePrologException v) = PrologResultNotAvailableException v


data PrologValue
    = Var Text
    | PrologValue Text
    | Functor Text [PrologValue]
    | List [PrologValue]
    deriving
        ( Eq
        , Show
        )


instance FromJSON PrologValue where
    parseJSON (J.Object obj) = Functor
        <$> obj .: "functor"
        <*> obj .: "args"

    parseJSON (J.String t) =
        return $ case T.uncons t of
            Just (first, _) | isUpper first -> Var t
            _ -> PrologValue t

    parseJSON (J.Array v) = List . V.toList <$> traverse parseJSON v

    parseJSON invalid =
        JT.prependFailure "parsing Prolog value failed, "
            (JT.unexpected invalid)


instance ToJSON PrologValue where
    toJSON (Functor name args) = J.object ["functor" .= name, "args" .= args]
    toJSON (PrologValue v) = J.String v
    toJSON (Var v) = J.String v
    toJSON (List vs) = toJSONList vs

    toEncoding (Functor name args) = J.pairs ("args" .= args <> "functor" .= name)
    toEncoding (PrologValue v) = toEncoding v
    toEncoding (Var v) = toEncoding v
    toEncoding (List vs) = toEncodingList vs


startProlog :: IO MQI
startProlog = do
    (_, Just out, Just err, processHandle) <- createProcess_ "startProlog" (proc "swipl" ["mqi","--write_connection_values=true"])
        { std_out = CreatePipe
        , std_err = CreatePipe
        }

    port <- C.unpack . C.strip <$> C.hGetLine out
    epassword <- TE.decodeUtf8' <$> C.hGetLine out
    case epassword of
        Left e -> E.throwIO e
        Right password ->
            return MQI
                { mqiStdout = out
                , mqiStderr = err
                , mqiProcessHandle = processHandle
                , mqiPort = port
                , mqiPassword = T.stripEnd password
                , mqiConnectionFailed = False
                }


stopProlog :: MQI -> IO ()
stopProlog mqi =
    cleanupProcess (Nothing, Just (mqiStdout mqi), Just (mqiStderr mqi), mqiProcessHandle mqi)
    

withProlog :: (MQI -> IO a) -> IO a
withProlog =
    E.bracket
        startProlog
        stopProlog


data PrologThread = PrologThread
    { prologThreadServer :: MQI
    , prologThreadSocket :: Socket
    , prologThreadCommunicationId :: Text
    , prologThreadGoalId :: Text
    , prologThreadServerProtocolMajor :: Text
    , prologThreadServerProtocolMinor :: Text
    }


bootstrapThread :: MQI -> Socket -> PrologThread
bootstrapThread mqi sock = PrologThread
    { prologThreadServer = mqi
    , prologThreadSocket = sock
    , prologThreadCommunicationId = ""
    , prologThreadGoalId = ""
    , prologThreadServerProtocolMajor = ""
    , prologThreadServerProtocolMinor = ""
    }


startPrologThread :: MQI -> IO PrologThread
startPrologThread mqi = do
    let hints = defaultHints{ addrSocketType = Stream }
    addr <- NE.head <$> getAddrInfo (Just hints) (Just "localhost") (Just $ mqiPort mqi)
    sock <- openSocket addr
    tryConnectSock sock (addrAddress addr)
    let thread = bootstrapThread mqi sock
    prologThreadSend (mqiPassword mqi) thread
    result <- prologThreadRecv thread
    case J.eitherDecodeStrictText result of
        Left e -> E.throwIO $ PrologLaunchException e
        Right (Functor "true"
            (List (List
                (Functor "threads" (PrologValue commId : PrologValue goalId : _)
                : Functor "version" (PrologValue major : PrologValue minor : _) : _) : _) : _)) ->
            return thread
                { prologThreadCommunicationId = commId
                , prologThreadGoalId = goalId
                , prologThreadServerProtocolMajor = major
                , prologThreadServerProtocolMinor = minor
                }

        _ -> E.throwIO . PrologLaunchException $ "Invalid bootstrap term: " ++ T.unpack result


-- This nonsense is required because of a race condition in Prolog MQI
tryConnectSock :: Socket -> SockAddr -> IO ()
tryConnectSock sock addr =
    connect sock addr `E.catch` \ ioe -> tryConnectSockLoop 1 ioe sock addr


maxRetries :: Int
maxRetries = 3


tryConnectSockLoop :: Int -> E.IOException -> Socket -> SockAddr -> IO ()
tryConnectSockLoop nretries deferredException sock addr
    | nretries >= maxRetries = E.throwIO deferredException
    | otherwise = do
        threadDelay 1_000_000
        connect sock addr `E.catch` \ ioe -> tryConnectSockLoop (nretries + 1) ioe sock addr


prologThreadSend :: Text -> PrologThread -> IO ()
prologThreadSend msg t = do
    let msgBytes = TE.encodeUtf8 $ clean msg
    sendAll (prologThreadSocket t) (C.pack (show $ C.length msgBytes) <> "\n." <> msgBytes <> "\n.")


clean :: Text -> Text
clean = T.dropWhileEnd (\ c -> c == '\n' || c == '.') . T.strip


recvLength :: Int
recvLength = 4096


prologThreadRecv :: PrologThread -> IO Text
prologThreadRecv = prologThreadRecvHeaderLoop C.empty


prologThreadRecvHeaderLoop :: ByteString -> PrologThread -> IO Text
prologThreadRecvHeaderLoop sizeBytes t = do
    headerData <- recv (prologThreadSocket t) recvLength
    let (before, after) = C.span (/= '\n') headerData
    let sizeBytes' = sizeBytes <> C.filter (/= '.') before
    if C.null after then
        prologThreadRecvHeaderLoop sizeBytes' t
    else case C.readInt sizeBytes' of
        Nothing -> E.throwIO (PrologRecvDecodingException sizeBytes')
        Just (size, _) ->
            let
                bodyBytes = C.drop 1 after
            in
                prologThreadRecvLoop size (C.length bodyBytes) bodyBytes t


prologThreadRecvLoop :: Int -> Int -> ByteString -> PrologThread -> IO Text
prologThreadRecvLoop amountExpected amountRecvd bodyBytes t
    | amountRecvd >= amountExpected =
        case TE.decodeUtf8' (C.dropWhileEnd (\ c -> c == '\n' || c == '.') $ C.strip bodyBytes) of
            Left e -> E.throwIO e
            Right finalBody -> return finalBody
    | otherwise = do
        bodyData <- recv (prologThreadSocket t) recvLength
        prologThreadRecvLoop amountExpected (amountRecvd + C.length bodyData) (bodyBytes <> bodyData) t


query :: PrologThread -> Text -> IO QueryResult
query = queryTimeout' Nothing


queryTimeout :: Double -> PrologThread -> Text -> IO QueryResult
queryTimeout = queryTimeout' . Just


queryTimeout' :: Maybe Double -> PrologThread -> Text -> IO QueryResult
queryTimeout' mtimeout t q = do
    let q' = clean q
    let timeoutString = maybe "_" (T.pack . show) mtimeout
    prologThreadSend ("run((" <> q' <> ")," <> timeoutString <> ")") t
    prologThreadDecodeResult t


data QueryResult
    = Failure
    | Success
    | Results [FreeVariableBinding]
    deriving
        ( Eq
        , Show
        )


data FreeVariableBinding
    = NoFreeVariables
    | VariableBindings (HashMap Text PrologValue)
    deriving
        ( Eq
        , Show
        )


prologThreadDecodeResult :: PrologThread -> IO QueryResult
prologThreadDecodeResult t = do
    result <- prologThreadRecv t
    case J.decodeStrictText result of
        Nothing -> E.throwIO . PrologRecvDecodingException $ TE.encodeUtf8 result
        Just (Functor "false" _) -> return Failure
        Just r@(Functor "exception" (PrologValue exceptionType : _)) ->
            case exceptionType of
                "connection_failed" -> E.throwIO $ PrologConnectionFailedException r
                "time_limit_exceeded" -> E.throwIO $ PrologQueryTimeoutException r
                "no_query" -> E.throwIO $ PrologNoQueryException r
                "cancel_goal" -> E.throwIO $ PrologQueryCancelledException r
                "result_not_available" -> E.throwIO $ PrologResultNotAvailableException r
                _ -> E.throwIO $ SomePrologException r
            
        Just (Functor "true" (List answers : _)) -> determineResults answers
        Just r -> E.throwIO $ SomePrologException r


determineResults :: [PrologValue] -> IO QueryResult
determineResults answers = do
    finalAnswers <- traverse finaliseResults answers
    if finalAnswers == [NoFreeVariables] then
        return Success
    else
        return (Results finalAnswers)


finaliseResults :: PrologValue -> IO FreeVariableBinding
finaliseResults (List []) = return NoFreeVariables
finaliseResults (List bindings) = VariableBindings <$> foldM aggregateBinding HM.empty bindings
finaliseResults r = E.throwIO $ SomePrologException r



aggregateBinding :: HashMap Text PrologValue -> PrologValue -> IO (HashMap Text PrologValue)
aggregateBinding bindings (Functor _ (Var left : right : _)) = return $ HM.insert left right bindings
aggregateBinding _ erroneousBinding = E.throwIO $ SomePrologException erroneousBinding