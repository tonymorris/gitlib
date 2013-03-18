{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RecordWildCards #-}

module Git.Utils where

import           Control.Applicative
import           Control.Exception as Exc
import           Control.Failure
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import           Data.Conduit
import qualified Data.Conduit.List as CList
import           Data.Default
import           Data.Function
import           Data.List
import           Data.Monoid
import           Data.Proxy
import           Data.Tagged
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Traversable hiding (mapM, sequence)
import           Debug.Trace (trace)
import           Filesystem (removeTree, isDirectory)
import           Filesystem.Path.CurrentOS hiding (null)
import           Git
import           Prelude hiding (FilePath)
import           System.IO.Unsafe

oid :: Treeish t => t -> TreeRepository t Text
oid t = renderObjOid <$> writeTree t

createBlobUtf8 :: Repository m => Text -> m (BlobOid m)
createBlobUtf8 = createBlob . BlobString . T.encodeUtf8

catBlob :: Repository m => Text -> m ByteString
catBlob str = do
    if len == 40
        then do
        oid <- parseOid str
        lookupBlob (Tagged oid) >>= blobToByteString

        else do
        obj <- lookupObject str
        case obj of
            BlobObj (ByOid oid) -> lookupBlob oid >>= blobToByteString
            BlobObj (Known x)   -> blobToByteString x
            _ -> failure (ObjectLookupFailed str len)
  where
    len = T.length str

catBlobUtf8 :: Repository m => Text -> m Text
catBlobUtf8 = catBlob >=> return . T.decodeUtf8

blobContentsToByteString :: Repository m => BlobContents m -> m ByteString
blobContentsToByteString (BlobString bs) = return bs
blobContentsToByteString (BlobStream bs) = do
    strs <- bs $$ CList.consume
    return (B.concat strs)
blobContentsToByteString (BlobSizedStream bs _) = do
    strs <- bs $$ CList.consume
    return (B.concat strs)

blobToByteString :: Repository m => Blob m -> m ByteString
blobToByteString (Blob _ contents) = blobContentsToByteString contents

treeBlobEntries :: Repository m => Tree m -> m [(FilePath,TreeEntry m)]
treeBlobEntries tree =
    mconcat <$> traverseEntries tree (\fp e -> case e of
                                           BlobEntry _ kind ->
                                               if kind == PlainBlob
                                               then return [(fp,e)]
                                               else return []
                                           _ -> return [])

commitTreeEntry :: Repository m
                => Commit m
                -> FilePath
                -> TreeRepository (Tree m)
                      (Maybe (TreeEntry (TreeRepository (Tree m))))
commitTreeEntry c path = flip lookupEntry path =<< resolveTreeRef (commitTree c)

copyOid :: (Repository m1, Repository m2) => Oid m1 -> m1 (m2 (Oid m2))
copyOid = return . parseOid . renderOid

copyBlob :: (Repository m1, Repository m2) => BlobRef m1 -> m1 (m2 (BlobOid m2))
copyBlob blobr = do
    let oid = unTagged (blobRefOid blobr)
    trace ("copyBlob " ++ show oid) $ return ()
    return $ do
        oid2    <- parseOid (renderOid oid)
        exists2 <- existsObject oid2
        trace ("copyBlob2 " ++ show oid2 ++ " exists " ++ show exists2) $ return ()
        if exists2
            then return (Tagged oid2)
            else do
                bs2 <- blobToByteString =<< resolveBlobRef (ByOid (Tagged oid2))
                createBlob (BlobString bs2)

copyTreeEntry :: (Repository m1, Repository m2)
              => TreeEntry m1 -> m1 (m2 (TreeEntry m2))
copyTreeEntry (BlobEntry oid kind) = do
    trace ("copyBlobEntry " ++ T.unpack (renderObjOid oid)) $ return ()
    blob2act <- copyBlob (ByOid oid)
    return $ do
        blob2oid <- blob2act
        return $ BlobEntry blob2oid kind

-- copyTreeEntry (TreeEntry tr) = do
--     tree2act <- copyTree tr
--     return $ do
--         tree2 <- tree2act
--         oid2  <- writeTree tree2
--         return $ TreeEntry (ByOid oid2)

copyTreeEntry (CommitEntry oid) = do
    trace ("copyCommitEntry " ++ T.unpack (renderObjOid oid)) $ return ()
    return $ do
        oid2 <- parseOid (renderObjOid oid)
        return $ CommitEntry (Tagged oid2)

copyTree :: (Repository m1, Repository m2) => TreeRef m1 -> m1 (m2 (Tree m2))
copyTree tr = do
    oid      <- unTagged <$> treeRefOid tr
    trace ("copyTree " ++ T.unpack (renderOid oid)) $ return ()
    tree     <- resolveTreeRef tr
    entries  <- traverseEntries tree (curry return)
    entries2 <- foldM (\acc (fp,ent) -> do
                           trace ("copyTreeEntry " ++ show fp) $ return ()
                           case ent of
                               TreeEntry {} -> return acc
                               _ -> do
                                   ent2 <- copyTreeEntry ent
                                   return $ (fp, ent2):acc) [] entries
    return $ do
        oid2    <- parseOid (renderOid oid)
        exists2 <- existsObject oid2
        trace ("copyTree2 " ++ T.unpack (renderOid oid2) ++ " exists " ++ show exists2) $ return ()
        if exists2
            then lookupTree (Tagged oid2)
            else do
                tree2 <- newTree
                forM_ entries2 $ \(fp,getEnt2) -> do
                    ent2 <- getEnt2
                    putTreeEntry tree2 fp ent2
                writeTree tree2
                return tree2

copyCommit :: (Repository m1, Repository m2)
           => CommitRef m1
           -> Maybe Text
           -> m1 (m2 (Commit m2))
copyCommit cr mref = do
    let oid = unTagged (commitRefOid cr)
    commit      <- resolveCommitRef cr
    trace ("copyCommit " ++ T.unpack (renderOid oid) ++ " " ++ show (commitLog commit)) $ return ()
    tree2act    <- copyTree (commitTree commit)
    parents2act <- mapM (flip copyCommit Nothing) (commitParents commit)
    return $ do
        oid2    <- parseOid (renderOid oid)
        exists2 <- existsObject oid2
        trace ("copyCommit2 " ++ T.unpack (renderOid oid2) ++ " exists " ++ show exists2) $ return ()
        if exists2
            then lookupCommit (Tagged oid2)
            else do
                tree2    <- tree2act
                parents2 <- mapM id parents2act
                createCommit
                    (map commitRef parents2)
                    (treeRef tree2)
                    (commitAuthor commit)
                    (commitCommitter commit)
                    (commitLog commit)
                    mref

genericPushRef :: (Repository m1, Repository m2)
               => Reference m1 (Commit m1)
               -> Text
               -> m1 (m2 (Maybe (Reference m2 (Commit m2))))
genericPushRef ref remoteRefName = do
    let name = refName ref
    mcr <- resolveRef name
    case mcr of
        Nothing -> return (return Nothing)
        Just cr -> do
            commit2act <- copyCommit cr (Just remoteRefName)
            lift $ do
                commit2 <- commit2act
                return . Just . Reference name . commitRefTarget $ commit2

commitHistoryFirstParent :: Repository m => Commit m -> m [Commit m]
commitHistoryFirstParent c =
    case commitParents c of
        []    -> return [c]
        (p:_) -> do ps <- commitHistoryFirstParent c
                    return (c:ps)

data PinnedEntry m = PinnedEntry
    { pinnedOid    :: Oid m
    , pinnedCommit :: Commit m
    , pinnedEntry  :: TreeEntry (TreeRepository (Tree m))
    }

identifyEntry :: Repository m => Commit m -> TreeEntry (TreeRepository (Tree m))
              -> m (PinnedEntry m)
identifyEntry co x = do
    oid <- case x of
        BlobEntry oid _ -> return (unTagged oid)
        TreeEntry ref   -> unTagged <$> treeRefOid ref
        CommitEntry oid -> return (unTagged oid)
    return (PinnedEntry oid co x)

commitEntryHistory :: Repository m => Commit m -> FilePath -> m [PinnedEntry m]
commitEntryHistory c path =
    map head . filter (not . null) . groupBy ((==) `on` pinnedOid) <$> go c
  where
    go co = do
        entry <- getEntry co
        rest  <- case commitParents co of
            []    -> return []
            (p:_) -> go =<< resolveCommitRef p
        return $ maybe rest (:rest) entry

    getEntry co = do
        ce <- commitTreeEntry co path
        case ce of
            Nothing  -> return Nothing
            Just ce' -> Just <$> identifyEntry co ce'

getCommitParents :: Repository m => Commit m -> m [Commit m]
getCommitParents = traverse resolveCommitRef . commitParents

resolveRefTree :: Repository m => Text -> m (Tree m)
resolveRefTree refName = do
    c <- resolveRef refName
    case c of
        Nothing -> newTree
        Just c' -> resolveCommitRef c' >>= resolveTreeRef . commitTree

-- Utils.hs ends here