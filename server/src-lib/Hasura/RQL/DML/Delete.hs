module Hasura.RQL.DML.Delete
  ( validateDeleteQWith
  , validateDeleteQ
  , AnnDelG(..)
  , traverseAnnDel
  , AnnDel
  , execDeleteQuery
  , runDelete
  ) where

import           Hasura.Prelude

import qualified Data.Environment                             as Env
import qualified Data.Sequence                                as DS
import qualified Database.PG.Query                            as Q

import           Control.Monad.Trans.Control                  (MonadBaseControl)
import           Data.Aeson

import qualified Hasura.Backends.Postgres.SQL.DML             as S
import qualified Hasura.Tracing                               as Tracing

import           Hasura.Backends.Postgres.Connection
import           Hasura.Backends.Postgres.Execute.Mutation
import           Hasura.Backends.Postgres.Translate.Returning
import           Hasura.EncJSON
import           Hasura.RQL.DML.Internal
import           Hasura.RQL.DML.Types
import           Hasura.RQL.IR.Delete
import           Hasura.RQL.Types
import           Hasura.RQL.Types.Run
import           Hasura.Server.Version                        (HasVersion)


validateDeleteQWith
  :: (UserInfoM m, QErrM m, TableInfoRM 'Postgres m)
  => SessVarBldr 'Postgres m
  -> (ColumnType 'Postgres -> Value -> m S.SQLExp)
  -> DeleteQuery
  -> m (AnnDel 'Postgres)
validateDeleteQWith sessVarBldr prepValBldr
  (DeleteQuery tableName rqlBE mRetCols) = do
  tableInfo <- askTabInfoSource tableName
  let coreInfo = _tiCoreInfo tableInfo

  -- If table is view then check if it deletable
  mutableView tableName viIsDeletable
    (_tciViewInfo coreInfo) "deletable"

  -- Check if the role has delete permissions
  delPerm <- askDelPermInfo tableInfo

  -- Check if all dependent headers are present
  validateHeaders $ dpiRequiredHeaders delPerm

  -- Check if select is allowed
  selPerm <- modifyErr (<> selNecessaryMsg) $
             askSelPermInfo tableInfo

  let fieldInfoMap = _tciFieldInfoMap coreInfo
      allCols = getCols fieldInfoMap

  -- convert the returning cols into sql returing exp
  mAnnRetCols <- forM mRetCols $ \retCols ->
    withPathK "returning" $ checkRetCols fieldInfoMap selPerm retCols

  -- convert the where clause
  annSQLBoolExp <- withPathK "where" $
    convBoolExp fieldInfoMap selPerm rqlBE sessVarBldr prepValBldr

  resolvedDelFltr <- convAnnBoolExpPartialSQL sessVarBldr $
                     dpiFilter delPerm

  return $ AnnDel tableName
    (resolvedDelFltr, annSQLBoolExp)
    (mkDefaultMutFlds mAnnRetCols) allCols

  where
    selNecessaryMsg =
      "; \"delete\" is only allowed if the role "
      <> "has \"select\" permission as \"where\" can't be used "
      <> "without \"select\" permission on the table"

validateDeleteQ
  :: (QErrM m, UserInfoM m, CacheRM m)
  => SourceName -> DeleteQuery -> m (AnnDel 'Postgres, DS.Seq Q.PrepArg)
validateDeleteQ source query = do
  tableCache <- askTableCache source
  flip runTableCacheRT (source, tableCache) $ runDMLP1T $
    validateDeleteQWith sessVarFromCurrentSetting binRHSBuilder query

runDelete
  :: ( HasVersion, QErrM m, UserInfoM m, CacheRM m
     , HasSQLGenCtx m, MonadIO m
     , MonadBaseControl IO m, Tracing.MonadTrace m
     )
  => Env.Environment
  -> SourceName
  -> DeleteQuery
  -> m EncJSON
runDelete env source q = do
  sourceConfig <- _pcConfiguration <$> askPGSourceCache source
  strfyNum <- stringifyNum <$> askSQLGenCtx
  validateDeleteQ source q >>= liftEitherM . runExceptT .
    runQueryLazyTx (_pscExecCtx sourceConfig) Q.ReadWrite . execDeleteQuery env strfyNum Nothing
