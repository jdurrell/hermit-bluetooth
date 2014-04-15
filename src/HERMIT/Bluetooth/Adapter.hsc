{-# LANGUAGE ForeignFunctionInterface, EmptyDataDecls #-}
{-# CFILES sdp_register_service.c #-}
module HERMIT.Bluetooth.Adapter (
        allAdapters,
        defaultAdapter,
        registerSDPService,
        closeSDPSession,
        socketRFCOMM,
        bindRFCOMM,
        listenRFCOMM,
        acceptRFCOMM,

        Adapter,
        BluetoothException(..),
        BluetoothAddr(..),
        SDPSession,
        SockAddrRFCOMM(..)
    ) where

#if defined(mingw32_HOST_OS)
#include <windows.h>
#else
#include <sys/socket.h>
#include <bluetooth/bluetooth.h>
#include <bluetooth/hci.h>
#include <bluetooth/sdp.h>
#include <bluetooth/sdp_lib.h>
#include "sdp_register_service.h"
#endif
#include <stddef.h>

import HERMIT.Bluetooth.Types
#if defined(mingw32_HOST_OS)
import HERMIT.Bluetooth.Win32
#endif

import Control.Applicative
import Control.Concurrent
import Control.Exception
import qualified Control.Monad as M
import Data.IORef
import Data.Word
import Foreign
import Foreign.C
import Network.Socket
-- import qualified System.Posix.Internals
#if defined(mingw32_HOST_OS)
import System.Win32.Types
#endif

#if !defined(mingw32_HOST_OS)
foreign import ccall safe "hci_for_each_dev"
    hci_for_each_dev :: CInt -> FunPtr (CInt -> CInt -> CLong -> IO CInt) -> CLong -> IO ()

foreign import ccall safe "wrapper"
    mkVisitDev :: (CInt -> CInt -> CLong -> IO CInt) -> IO (FunPtr (CInt -> CInt -> CLong -> IO CInt))

foreign import ccall safe "hci_open_dev"
    hci_open_dev :: CInt -> IO CInt
    
foreign import ccall unsafe "sdp_register_service"
    sdp_register_service :: CUChar -> CUChar -> IO SDPSession

foreign import ccall unsafe "sdp_close"
    sdp_close :: SDPSession -> IO CInt

foreign import ccall unsafe "socket"
    c_socket :: CInt -> CInt -> CInt -> IO CInt

foreign import ccall unsafe "bind"
    c_bind :: CInt -> Ptr SockAddrRFCOMM -> CInt -> IO CInt

foreign import ccall unsafe "listen"
    c_listen :: CInt -> CInt -> IO CInt

foreign import ccall unsafe "accept"
    c_accept :: CInt -> Ptr SockAddrRFCOMM -> Ptr CUInt -> IO CInt
#endif

#if !defined(mingw32_HOST_OS)
openDev :: CInt -> IO Adapter
openDev dev_id = do
    ret <- hci_open_dev dev_id
    if ret < 0 then do
        errno@(Errno errno_) <- getErrno
        if errno == eINTR
            then openDev dev_id
            else do
                err <- peekCString (strerror errno_)
                throwIO $ BluetoothException "openDev" err
      else
        pure $ Adapter dev_id ret
#endif

allAdapters :: IO [Adapter]
#if defined(mingw32_HOST_OS)
allAdapters = return [Adapter]
#else
allAdapters = do
    devsRef <- newIORef []
    cb <- mkVisitDev $ \_ dev_id _ -> do
        modifyIORef devsRef (dev_id:)
        pure 0
    hci_for_each_dev (#const HCI_UP) cb 0
      `finally`
        freeHaskellFunPtr cb
    dev_ids <- reverse <$> readIORef devsRef
    mapM openDev dev_ids
#endif

#if !defined(mingw32_HOST_OS)
foreign import ccall unsafe "hci_get_route" hci_get_route
    :: Ptr BluetoothAddr -> IO CInt
#endif

defaultAdapter :: IO (Maybe Adapter)
#if defined(mingw32_HOST_OS)
defaultAdapter = return $ Just Adapter
#else
defaultAdapter = do
    ret <- hci_get_route nullPtr
    if ret < 0 then do
        errno@(Errno errno_) <- getErrno
        if errno == eINTR
            then defaultAdapter
          else if errno == eNODEV
            then pure Nothing
            else do
                err <- peekCString (strerror errno_)
                throwIO $ BluetoothException "defaultAdapter" err
      else
        Just <$> openDev ret
#endif

mAX_CONNECTIONS :: Num a => a
mAX_CONNECTIONS = 7

#if !defined(mingw32_HOST_OS)
bTPROTO_RFCOMM :: ProtocolNumber
bTPROTO_RFCOMM = (#const BTPROTO_RFCOMM)

registerSDPService :: Word8 -> Word8 -> IO SDPSession
registerSDPService ind port = sdp_register_service (CUChar safeInd) (CUChar port)
    where safeInd | 0 <= ind && ind < mAX_CONNECTIONS = ind
                  | otherwise = 0

closeSDPSession :: SDPSession -> IO ()
closeSDPSession = M.void . sdp_close

socketRFCOMM :: IO Socket
socketRFCOMM = do
    c_stype <- packSocketTypeOrThrow "socketRFCOMM" Stream
    fd <- throwSocketErrorIfMinus1 "socketRFCOMM" $ c_socket (packFamily AF_BLUETOOTH) c_stype bTPROTO_RFCOMM
    print fd
    socket_status <- newMVar NotConnected
    return $ MkSocket fd AF_BLUETOOTH Stream bTPROTO_RFCOMM socket_status

bindRFCOMM :: Socket -> SockAddrRFCOMM -> IO ()
bindRFCOMM (MkSocket s _family _stype _protocol socketStatus) addr = do
    modifyMVar_ socketStatus $ \ status -> do
        if status /= NotConnected
           then ioError (userError ("bindRFCOMM: can't perform bind on socket in status " ++ show status))
           else do
               withSockAddrRFCOMM addr $ \ p_addr sz -> do
                   _ <- throwSocketErrorIfMinus1 "bind" $ c_bind s p_addr $ fromIntegral sz
                   return Bound

throwSocketErrorIfMinus1 :: (Eq a, Num a) => String -> IO a -> IO a
throwSocketErrorIfMinus1 = throwErrnoIfMinus1

listenRFCOMM :: Socket -> Int -> IO ()
listenRFCOMM (MkSocket s _family _stype _protocol socketStatus) backlog = do
    modifyMVar_ socketStatus $ \ status -> do
        if status /= Bound
           then ioError (userError ("listenRFCOMM: can't peform listen on socket in status " ++ show status))
           else do
               _ <- throwSocketErrorIfMinus1 "listenRFCOMM" (c_listen s (fromIntegral backlog))
               return Listening

acceptRFCOMM :: Socket -> IO (Socket, SockAddrRFCOMM)
acceptRFCOMM (MkSocket s family stype protocol socketStatus) = do
    status <- readMVar socketStatus
    if status /= Listening
       then ioError (userError ("acceptRFCOMM: can't perform accept on socket in status" ++ show status))
       else do
           let sz = sizeOfSockAddrRFCOMM
           allocaBytes sz $ \ sockaddr -> do
               with (fromIntegral sz) $ \ ptr_len -> do
                   new_sock <- throwSocketErrorIfMinus1 "acceptRFCOMM" $ c_accept s sockaddr ptr_len
                   addr <- peekSockAddrRFCOMM sockaddr
                   new_status <- newMVar Connected
                   return ((MkSocket new_sock family stype protocol new_status), addr)
#endif