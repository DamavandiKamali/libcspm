module CSPM.TypeChecker.Monad (
    readTypeRef, writeTypeRef, freshTypeVar, freshTypeVarWithConstraints,
    getType, setType, 
    isTypeUnsafe, markTypeAsUnsafe, 
    replacementForDeprecatedName, isDeprecated, markAsDeprecated,
    compress, compressTypeScheme, 
    
    TypeCheckMonad, runTypeChecker, 
    newTypeInferenceState,  TypeInferenceState(..), getState,
    
    local, getEnvironment,
    ErrorContext, addErrorContext, getErrorContexts,
    getSrcSpan, setSrcSpan,
    getUnificationStack, addUnificationPair,
    symmetricUnificationAllowed, disallowSymmetricUnification,
    getInError, setInError,
    resetWarnings, getWarnings, addWarning,
    markDatatypeAsComparableForEquality,
    datatypeIsComparableForEquality,
    unmarkDatatypeAsComparableForEquality,
    modifyErrorOptions,
    addDefinitionName, getDefinitionStack,
    
    raiseMessageAsError, raiseMessagesAsError, panic,
    manyErrorsIfFalse, errorIfFalseM, errorIfFalse, tryAndRecover, failM,
)
where

import Control.Monad.State
import Data.List ((\\))
import Prelude hiding (lookup)

import CSPM.DataStructures.Names
import CSPM.DataStructures.Types
import qualified CSPM.TypeChecker.Environment as Env
import CSPM.TypeChecker.Exceptions
import Util.Annotated
import Util.Exception
import qualified Util.Monad as M
import Util.PrettyPrint

-- *************************************************************************
-- Type Checker Monad
-- *************************************************************************
type ErrorContext = Doc

data TypeInferenceState = TypeInferenceState {
        -- | The type environment, which is a map from names to types.
        environment :: Env.Environment,
        -- | Location of the current AST element - used for error
        -- pretty printing
        srcSpan :: SrcSpan,
        -- | Error stack - provides context information for any
        -- errors that might be raised
        errorContexts :: [ErrorContext],
        -- | Errors that have occured
        errors :: [ErrorMessage],
        -- | List of warnings that have occured
        warnings :: [ErrorMessage],
        -- | Stack of attempted unifications - the current one
        -- is at the front. In the form (expected, actual).
        unificationStack :: [(Type, Type)],
        -- | The stack of names that we are currently type-checking.
        definitionStack :: [Name],
        -- | Are we currently in an error state
        inError :: Bool,
        symUnificationAllowed :: Bool,
        -- | The set of datatypes that can be compared for equality.
        comparableForEqualityDataTypes :: [Name],
        -- | The error options to use
        errorOptions :: ErrorOptions
    }
    
newTypeInferenceState :: TypeInferenceState
newTypeInferenceState = TypeInferenceState {
        environment = Env.new,
        srcSpan = Unknown,
        errorContexts = [],
        errors = [],
        warnings = [],
        unificationStack = [],
        definitionStack = [],
        inError = False,
        symUnificationAllowed = True,
        comparableForEqualityDataTypes = [],
        errorOptions = defaultErrorOptions
    }

type TypeCheckMonad = StateT TypeInferenceState IO

-- | Runs the typechecker, starting from state 'st'. If any errors are
-- encountered then a 'SourceError' will be thrown with the relevent
-- error messages.
runTypeChecker :: TypeInferenceState -> TypeCheckMonad a -> IO a
runTypeChecker st prog = do
    (a, st) <- runStateT prog st
    let errs = errors st
    case errs of
        [] -> return a
        _ -> throwSourceError errs

getState :: TypeCheckMonad TypeInferenceState
getState = gets id

modifyErrorOptions :: (ErrorOptions -> ErrorOptions) -> TypeCheckMonad ()
modifyErrorOptions f = modify (\st -> st { errorOptions = f (errorOptions st)})

getEnvironment :: TypeCheckMonad Env.Environment
getEnvironment = gets environment

setEnvironment :: Env.Environment -> TypeCheckMonad ()
setEnvironment env = modify (\ st -> st { environment = env })

local :: [Name] -> TypeCheckMonad a -> TypeCheckMonad a
local ns m = 
    do
        env <- getEnvironment
        newArgs <- replicateM (length ns) freshTypeVar
        let symbs = map (Env.mkSymbolInformation . ForAll []) newArgs
        setEnvironment (Env.bind env (zip ns symbs))
        
        res <- m
    
        env <- getEnvironment
        setEnvironment (foldr (flip Env.delete) env ns)

        return res

getErrorContexts :: TypeCheckMonad [ErrorContext]
getErrorContexts = gets errorContexts

addErrorContext :: ErrorContext -> TypeCheckMonad a -> TypeCheckMonad a
addErrorContext c p = do
    ctxts <- getErrorContexts
    modify (\st -> st { errorContexts = c:ctxts })
    a <- p
    modify (\st -> st { errorContexts = ctxts })
    return a
    
getErrors :: TypeCheckMonad ErrorMessages
getErrors = gets errors

addErrors :: [ErrorMessage] -> TypeCheckMonad ()
addErrors es = modify (\ st -> st { errors = es++(errors st) })

getWarnings :: TypeCheckMonad [ErrorMessage]
getWarnings = gets warnings

resetWarnings :: TypeCheckMonad ()
resetWarnings = modify (\st -> st { warnings = [] })

addWarning :: (ErrorOptions -> Bool) -> Warning -> TypeCheckMonad ()
addWarning warningType w = do
    -- Check and see if the warning is enabled
    errorOpts <- gets errorOptions
    when (warningType errorOpts) $ do
        src <- getSrcSpan
        let m = mkWarningMessage src w
        modify (\ st -> st { warnings = m:(warnings st) })

getInError :: TypeCheckMonad Bool
getInError = gets inError

setInError :: Bool -> TypeCheckMonad a -> TypeCheckMonad a
setInError b prog = do
    o <- getInError
    modify (\st -> st { inError = b })
    a <- prog
    modify (\st -> st { inError = o })
    return a

getSrcSpan :: TypeCheckMonad SrcSpan
getSrcSpan = gets srcSpan

-- | Sets the SrcSpan only within prog.
setSrcSpan :: SrcSpan -> TypeCheckMonad a -> TypeCheckMonad a
setSrcSpan loc prog = do
    oLoc <- getSrcSpan
    modify (\st -> st { srcSpan = loc })
    a <- prog
    modify (\st -> st { srcSpan = oLoc })
    return a

getUnificationStack :: TypeCheckMonad [(Type, Type)]
getUnificationStack = gets unificationStack

addUnificationPair :: (Type, Type) -> TypeCheckMonad a -> TypeCheckMonad a
addUnificationPair tp p = do
    stk <- getUnificationStack
    modify (\st -> st { unificationStack = tp:stk })
    a <- p
    modify (\ st -> st { unificationStack = stk })
    return a

addDefinitionName :: Name -> TypeCheckMonad a -> TypeCheckMonad a
addDefinitionName n prog = do
    modify (\st -> st { definitionStack = n : (definitionStack st) })
    a <- prog
    modify (\st -> st { definitionStack = tail (definitionStack st) })
    return a

getDefinitionStack :: TypeCheckMonad [Name]
getDefinitionStack = gets definitionStack

symmetricUnificationAllowed :: TypeCheckMonad Bool
symmetricUnificationAllowed = gets symUnificationAllowed

disallowSymmetricUnification :: TypeCheckMonad a -> TypeCheckMonad a
disallowSymmetricUnification prog = do
    b <- symmetricUnificationAllowed
    modify (\st -> st { symUnificationAllowed = False })
    v <- prog
    modify (\st -> st { symUnificationAllowed = b })
    return v
    
markDatatypeAsComparableForEquality :: Name -> TypeCheckMonad ()
markDatatypeAsComparableForEquality n =
    modify (\st -> st { 
        comparableForEqualityDataTypes = n : comparableForEqualityDataTypes st
    })

unmarkDatatypeAsComparableForEquality :: Name -> TypeCheckMonad ()
unmarkDatatypeAsComparableForEquality n =
    modify (\st -> st { 
        comparableForEqualityDataTypes = comparableForEqualityDataTypes st \\ [n]
    })

datatypeIsComparableForEquality :: Name -> TypeCheckMonad Bool
datatypeIsComparableForEquality n = do
    ds <- gets comparableForEqualityDataTypes
    return $ n `elem` ds

-- Error handling

-- | Report the error if first parameter is False.
errorIfFalse :: Bool -> Error -> TypeCheckMonad ()
errorIfFalse b e = manyErrorsIfFalse b [e]

manyErrorsIfFalse :: Bool -> [Error] -> TypeCheckMonad ()
manyErrorsIfFalse True es = return ()
manyErrorsIfFalse False es = raiseMessagesAsError es

errorIfFalseM :: TypeCheckMonad Bool -> Error -> TypeCheckMonad ()
errorIfFalseM m e = m >>= \res -> errorIfFalse res e

failM :: TypeCheckMonad a
failM = do
    errs <- getErrors
    throwSourceError errs

raiseMessageAsError :: Error -> TypeCheckMonad a
raiseMessageAsError msg = raiseMessagesAsError [msg]

-- | Report a message as an error
raiseMessagesAsError :: [Error] -> TypeCheckMonad a
raiseMessagesAsError msgs = do
    src <- getSrcSpan
    ctxts <- getErrorContexts
    let ctxtDocs = ctxts
    let contextMsg = trimAndRenderContexts maxContexts ctxtDocs
    addErrors [mkErrorMessage src (msg $$ contextMsg) | msg <- msgs]
    failM
    where
        -- Don't print too much context
        trimAndRenderContexts 0 _ = empty
        trimAndRenderContexts n [] = empty
        trimAndRenderContexts n (doc:docs) = 
            doc $$ trimAndRenderContexts (n-1) docs
        maxContexts = 3

tryAndRecover :: Bool -> TypeCheckMonad a -> TypeCheckMonad a -> TypeCheckMonad a
tryAndRecover retainErrors prog handler = tryM prog >>= \x ->
    case x of
        Right a -> return a
        Left ex -> case ex of
            SourceError msgs -> do
                -- The errors will be discarded as the errors propogate up.
                -- Hence, we reset them.
                when retainErrors $ setErrors msgs
                handler
            UserError -> handler
            -- An exception type we don't want to interfer with
            e           -> throwException e
    where
        setErrors :: ErrorMessages -> TypeCheckMonad ()
        setErrors es = modify (\ st -> st { errors = es })  


-- *************************************************************************
-- Type Operations
-- *************************************************************************
readTypeRef :: TypeVarRef -> TypeCheckMonad (Either (TypeVar, [Constraint]) Type)
readTypeRef (TypeVarRef tv cs ioref) = do
    mtyp <- readPType ioref
    case mtyp of
        Just t  -> return (Right t)
        Nothing -> return (Left (tv, cs))
readTypeRef (RigidTypeVarRef tv cs _) = return $ Left (tv, cs)

writeTypeRef :: TypeVarRef -> Type -> TypeCheckMonad ()
writeTypeRef (TypeVarRef tv cs ioref) t = setPType ioref t

getSymbolInformation :: Name -> TypeCheckMonad Env.SymbolInformation
getSymbolInformation n = do
    env <- gets environment
    -- Force evaluation of lookup n
    -- If we don't do this the error is deferred until later
    case Env.maybeLookup env n of
        Just symb -> return symb
        Nothing -> panic $ "Name "++show n++" not found after renaming."

-- | Get the type of 'n' and throw an exception if it doesn't exist.
getType :: Name -> TypeCheckMonad TypeScheme
getType n = do
    symb <- getSymbolInformation n
    return $ Env.typeScheme symb
    
-- | Sets the type of n to be t in the current scope only. No unification is 
-- performed.
setType :: Name -> TypeScheme -> TypeCheckMonad ()
setType n t = do
    env <- getEnvironment
    case Env.maybeLookup env n of
        Just symb -> setSymbolInformation n (symb { Env.typeScheme = t })
        Nothing -> setSymbolInformation n (Env.mkSymbolInformation t)

setSymbolInformation :: Name -> Env.SymbolInformation -> TypeCheckMonad ()
setSymbolInformation n symb = do
    env <- getEnvironment
    setEnvironment (Env.update env n symb)

isDeprecated :: Name -> TypeCheckMonad Bool
isDeprecated n = do
    symb <- getSymbolInformation n
    return $ Env.isDeprecated symb

isTypeUnsafe :: Name -> TypeCheckMonad Bool
isTypeUnsafe n = do
    symb <- getSymbolInformation n
    return $ Env.isTypeUnsafe symb

markAsDeprecated :: Name -> Maybe Name -> TypeCheckMonad ()
markAsDeprecated n repl = do
    symb <- getSymbolInformation n
    setSymbolInformation n (symb { 
        Env.isDeprecated = True, 
        Env.deprecationReplacement = repl
    })
markTypeAsUnsafe :: Name -> TypeCheckMonad ()
markTypeAsUnsafe n = do
    symb <- getSymbolInformation n
    setSymbolInformation n (symb { Env.isTypeUnsafe = True })

replacementForDeprecatedName :: Name -> TypeCheckMonad (Maybe Name)
replacementForDeprecatedName n = do
    symb <- getSymbolInformation n
    return $ Env.deprecationReplacement symb

-- | Apply compress to the type of a type scheme.
compressTypeScheme :: TypeScheme -> TypeCheckMonad TypeScheme
compressTypeScheme (ForAll ts t) = 
    do
        t' <- compress t
        return $ ForAll ts t'

-- | Takes a type and compresses the type by reading all type variables and
-- if they point to another type, it returns that type instead.
compress :: Type -> TypeCheckMonad Type
compress (tr @ (TVar typeRef)) = do
    res <- readTypeRef typeRef
    case res of
        Left tv -> return tr
        Right t -> compress t
compress (TFunction targs tr) = do
    targs' <- mapM compress targs
    tr' <- compress tr
    return $ TFunction targs' tr'
compress (TSeq t) = compress t >>= return . TSeq
compress (TSet t) = compress t >>= return . TSet
compress (TMap t1 t2) = return TMap M.$$ compress t1 M.$$ compress t2
compress (TTuple ts) = mapM compress ts >>= return . TTuple
compress (TDotable t1 t2)= do
    t1' <- compress t1
    t2' <- compress t2
    return $ TDotable t1' t2'
compress (TDatatype n) = return $ TDatatype n
compress (TDot t1 t2) = do
    t1' <- compress t1
    t2' <- compress t2
    return $ TDot t1' t2'
compress (tr @ (TExtendable t pt)) = do
    t <- compress t
    let extract (Just pt) (Left tv) = return $! TExtendable t pt
        extract _ (Right TExtendableEmptyDotList) = return t
        extract _ (Right (TVar pt')) = extractFromTExtendable pt'
        extract _ (Right (TDotable argt rt)) = do
            rt' <- extract Nothing (Right rt)
            argt' <- compress argt
            return $ TDotable argt' rt'
        extract _ (Right t) = panic ("Cannot extract from "++show t)

        extractFromTExtendable pt = readTypeRef pt >>= extract (Just pt)

    extractFromTExtendable pt
compress t = return t
