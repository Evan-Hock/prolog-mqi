{-# LANGUAGE OverloadedStrings #-}

module PrologMQI
    ( -- starting and stopping the prolog server
      startProlog, stopProlog, withProlog

    , startPrologThread, stopPrologThread, withPrologThread
    ) where


import qualified Data.List.NonEmpty as NE
import qualified Data.ByteString.Char8 as C
import Data.ByteString.Char8 (ByteString)
import Network.Socket
import Network.Socket.ByteString
import System.Process


data MQI = MQI
    { mqiStdout :: Handle
    , mqiStderr :: Handle
    , mqiProcessHandle :: ProcessHandle
    , mqiPort :: ByteString
    , mqiPassword :: ByteString
    }


startProlog :: IO MQI
startProlog = do
    (_, Just mqiStdout, Just mqiStderr, processHandle) <- createProcess_ "PrologMQI.start" (proc "swipl" ["mqi","--write_connection_values=true"])
        { std_out = CreatePipe
        , std_err = CreatePipe
        }

    port <- C.hGetLine mqiStdout
    password <- C.hGetLine mqiStdout
    return MQI
        { mqiStdout = mqiStdout
        , mqiStderr = mqiStderr
        , mqiProcessHandle = processHandle
        , mqiPort = port
        , mqiPassword = password
        }


stopProlog :: MQI -> IO ()
stopProlog mqi =
    cleanupProcess (Nothing, Just (mqiStdout mqi), Just (mqiStderr mqi), mqiProcessHandle mqi)


data PrologThread =
    { prologThreadServer :: MQI
    , prologThreadSocket :: Socket
    }


startPrologThread :: MQI -> IO PrologThread
startPrologThread mqi = do
    let hints = defaultHints{ addrSocketType = Stream }
    addr <- NE.head <$> getAddrInfo (Just hints) (Just "127.0.0.1") (Just $ mqiPort mqi)
    sock <- openSocket addr
    bind sock $ addrAddress addr
    sendAll sock $ mqiPassword mqi
    return PrologThread
        { prologThreadServer = mqi
        , prologThreadSocket = sock
        }
