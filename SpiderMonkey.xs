/* --------------------------------------------------------------------- */
/* SpiderMonkey.xs -- Perl Interface to the SpiderMonkey JavaScript      */
/*                    implementation (mozjs-60 and mozjs-78).             */
/*                                                                       */
/* Author: Mike Schilli mschilli1@aol.com, 2001                          */
/* Updated for mozjs60 by Thomas Busch, 2024                             */
/* --------------------------------------------------------------------- */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/* Perl defines macros that conflict with Mozilla C++ headers */
#undef Move
#undef Copy
#undef Zero
#undef Pause
#undef seed
#undef Bit

#include "jsapi.h"
#include "js/Initialization.h"
#include "js/Conversions.h"

#if MOZJS_MAJOR_VERSION >= 78
#include "js/CompilationAndEvaluation.h"
#include "js/SourceText.h"
#include "js/Array.h"
#include "js/Warnings.h"
#include "js/CharacterEncoding.h"
#endif

#include "SpiderMonkey.h"

/* Re-define Perl memory macros under safe names */
#define PerlMove(s,d,n,t) memmove((char*)(d),(const char*)(s), (n) * sizeof(t))
#define PerlCopy(s,d,n,t) memcpy((char*)(d),(const char*)(s), (n) * sizeof(t))
#define PerlZero(d,n,t)   memset((char*)(d), 0, (n) * sizeof(t))

/* --------------------------------------------------------------------- */
/* Compat helpers for JS_EncodeString (mozjs-60) vs                      */
/* JS_EncodeStringToLatin1 (mozjs-78, returns UniqueChars)               */
/* --------------------------------------------------------------------- */
#if MOZJS_MAJOR_VERSION >= 78
  static JS::UniqueChars EncodeString(JSContext *cx, JSString *str) {
      return JS_EncodeStringToLatin1(cx, str);
  }
  #define SM_ENCODED_CHARS(uc)     ((uc).get())
  #define SM_FREE_ENCODED(cx, uc)  /* no-op: UniqueChars auto-frees */
  typedef JS::UniqueChars EncodedString;
#else
  static char* EncodeString(JSContext *cx, JSString *str) {
      return JS_EncodeString(cx, str);
  }
  #define SM_ENCODED_CHARS(raw)    (raw)
  #define SM_FREE_ENCODED(cx, raw) JS_free(cx, raw)
  typedef char* EncodedString;
#endif

/* Global class ops - all nullptr for minimal class */
static const JSClassOps global_class_ops = {
    nullptr,  /* addProperty */
    nullptr,  /* delProperty */
    nullptr,  /* enumerate */
    nullptr,  /* newEnumerate */
    nullptr,  /* resolve */
    nullptr,  /* mayResolve */
    nullptr,  /* finalize */
    nullptr,  /* call */
    nullptr,  /* hasInstance */
    nullptr,  /* construct */
    JS_GlobalObjectTraceHook  /* trace */
};

static JSClass global_class = {
    "Global",
    JSCLASS_GLOBAL_FLAGS,
    &global_class_ops
};

static bool js_engine_initialized = false;
static JSContext *active_context = nullptr;

/* --------------------------------------------------------------------- */
/* Property value store for accessor properties                           */
/* In mozjs60, accessor properties have no underlying slot storage.       */
/* We manage values in a Perl hash keyed by "obj_addr/prop_name".         */
/* --------------------------------------------------------------------- */
static HV *prop_store = nullptr;

static void prop_store_init(void) {
    if (!prop_store)
        prop_store = newHV();
}

static void prop_store_clear(void) {
    if (prop_store) {
        hv_clear(prop_store);
    }
}

static void prop_store_destroy(void) {
    if (prop_store) {
        SvREFCNT_dec((SV*)prop_store);
        prop_store = nullptr;
    }
}

static void prop_store_set(void *obj, const char *name, const char *value) {
    prop_store_init();
    char key[256];
    snprintf(key, sizeof(key), "%p/%s", obj, name);
    hv_store(prop_store, key, strlen(key), newSVpv(value, 0), 0);
}

static const char* prop_store_get(void *obj, const char *name) {
    prop_store_init();
    char key[256];
    snprintf(key, sizeof(key), "%p/%s", obj, name);
    SV **svp = hv_fetch(prop_store, key, strlen(key), 0);
    if (svp && SvOK(*svp))
        return SvPV_nolen(*svp);
    return nullptr;
}

/* --------------------------------------------------------------------- */
/* Getter/setter dispatchers for accessor properties                      */
/* --------------------------------------------------------------------- */

#if MOZJS_MAJOR_VERSION >= 78
/* mozjs-78: JSNative-based getter/setter. The property name is retrieved
 * from the callee function's name (set via JS_NewFunction). */
static bool getter_native(JSContext *cx, unsigned argc, JS::Value *vp);
static bool setter_native(JSContext *cx, unsigned argc, JS::Value *vp);
#endif

static void call_perl_getsetter(
    JSContext *cx,
    void *obj_ptr,
    const char *prop_name,
    const char *value_str,
    const char *what
) {
    dSP;

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSViv(PTR2IV(obj_ptr))));
    XPUSHs(sv_2mortal(newSVpv(prop_name, 0)));
    XPUSHs(sv_2mortal(newSVpv(what, 0)));
    XPUSHs(sv_2mortal(newSVpv(value_str ? value_str : "", 0)));
    PUTBACK;
    call_pv("JavaScript::SpiderMonkey::getsetter_dispatcher", G_DISCARD);
    FREETMPS;
    LEAVE;
}

#if MOZJS_MAJOR_VERSION < 78
/* --------------------------------------------------------------------- */
/* mozjs-60: property-op based getter/setter (HandleId provides name)     */
/* --------------------------------------------------------------------- */
static bool getter_dispatcher(
    JSContext *cx,
    JS::HandleObject obj,
    JS::HandleId id,
    JS::MutableHandleValue vp
) {
    if (!JSID_IS_STRING(id))
        return true;

    char *prop_name = JS_EncodeString(cx, JSID_TO_STRING(id));
    if (!prop_name)
        return false;

    /* Look up stored value */
    const char *val_str = prop_store_get((void*)obj.get(), prop_name);

    /* Set the return value from our store */
    if (val_str) {
        JSString *str = JS_NewStringCopyZ(cx, val_str);
        if (str)
            vp.setString(str);
    }

    /* Call Perl getter callback */
    call_perl_getsetter(cx, (void*)obj.get(), prop_name, val_str, "getter");

    JS_free(cx, prop_name);
    return true;
}

/* --------------------------------------------------------------------- */
static bool setter_dispatcher(
    JSContext *cx,
    JS::HandleObject obj,
    JS::HandleId id,
    JS::HandleValue v,
    JS::ObjectOpResult &result
) {
    if (!JSID_IS_STRING(id)) {
        result.succeed();
        return true;
    }

    char *prop_name = JS_EncodeString(cx, JSID_TO_STRING(id));
    if (!prop_name)
        return false;

    /* Convert value to string */
    JS::RootedString str(cx, JS::ToString(cx, v));
    char *val_str = nullptr;
    if (str)
        val_str = JS_EncodeString(cx, str);

    /* Store value */
    prop_store_set((void*)obj.get(), prop_name, val_str ? val_str : "");

    /* Call Perl setter callback */
    call_perl_getsetter(cx, (void*)obj.get(), prop_name, val_str, "setter");

    if (val_str)
        JS_free(cx, val_str);
    JS_free(cx, prop_name);

    result.succeed();
    return true;
}

#else /* MOZJS_MAJOR_VERSION >= 78 */
/* --------------------------------------------------------------------- */
/* mozjs-78: JSNative getter/setter.  The property name is embedded in    */
/* the callee function object (created via JS_NewFunction with the        */
/* property name).                                                        */
/* --------------------------------------------------------------------- */
static bool getter_native(JSContext *cx, unsigned argc, JS::Value *vp) {
    JS::CallArgs args = JS::CallArgsFromVp(argc, vp);

    JS::RootedValue calleeVal(cx, args.calleev());
    JSFunction *fun = JS_ValueToFunction(cx, calleeVal);
    JSString *nameStr = JS_GetFunctionId(fun);
    if (!nameStr)
        return true;

    EncodedString name = EncodeString(cx, nameStr);
    if (!SM_ENCODED_CHARS(name))
        return false;

    JS::RootedObject thisObj(cx);
    if (args.thisv().isObject())
        thisObj = &args.thisv().toObject();
    else
        return true;

    const char *val = prop_store_get(thisObj.get(), SM_ENCODED_CHARS(name));

    if (val) {
        JSString *str = JS_NewStringCopyZ(cx, val);
        if (str)
            args.rval().setString(str);
    }

    call_perl_getsetter(cx, thisObj.get(), SM_ENCODED_CHARS(name), val, "getter");
    SM_FREE_ENCODED(cx, name);
    return true;
}

static bool setter_native(JSContext *cx, unsigned argc, JS::Value *vp) {
    JS::CallArgs args = JS::CallArgsFromVp(argc, vp);

    JS::RootedValue calleeVal(cx, args.calleev());
    JSFunction *fun = JS_ValueToFunction(cx, calleeVal);
    JSString *nameStr = JS_GetFunctionId(fun);
    if (!nameStr)
        return true;

    EncodedString name = EncodeString(cx, nameStr);
    if (!SM_ENCODED_CHARS(name))
        return false;

    JS::RootedObject thisObj(cx);
    if (args.thisv().isObject())
        thisObj = &args.thisv().toObject();
    else
        return true;

    /* Convert the first argument (the new value) to string */
    const char *val_cstr = "";
    EncodedString val_str(nullptr);
    if (argc > 0) {
        JS::RootedString str(cx, JS::ToString(cx, args[0]));
        if (str) {
            val_str = EncodeString(cx, str);
            if (SM_ENCODED_CHARS(val_str))
                val_cstr = SM_ENCODED_CHARS(val_str);
        }
    }

    prop_store_set(thisObj.get(), SM_ENCODED_CHARS(name), val_cstr);
    call_perl_getsetter(cx, thisObj.get(), SM_ENCODED_CHARS(name), val_cstr, "setter");

    SM_FREE_ENCODED(cx, val_str);
    SM_FREE_ENCODED(cx, name);
    args.rval().setUndefined();
    return true;
}
#endif /* MOZJS_MAJOR_VERSION >= 78 */

/* --------------------------------------------------------------------- */
static bool
FunctionDispatcher(JSContext *cx, unsigned argc, JS::Value *vp) {
/* --------------------------------------------------------------------- */
    dSP;
    JS::CallArgs args = JS::CallArgsFromVp(argc, vp);

    SV          *sv;
    char        *n_jstr;
    int         n_jnum;
    double      n_jdbl;
    unsigned    i;
    int         count;

    JS::RootedValue calleeVal(cx, args.calleev());
    JSFunction *fun = JS_ValueToFunction(cx, calleeVal);

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);

    /* Push 'this' object pointer */
    JS::RootedObject thisObj(cx);
    if (args.thisv().isObject()) {
        thisObj = &args.thisv().toObject();
    }
    XPUSHs(sv_2mortal(newSViv(PTR2IV(thisObj.get()))));

    /* Push function name */
    JSString *funId = JS_GetFunctionId(fun);
    if (funId) {
        EncodedString fname = EncodeString(cx, funId);
        XPUSHs(sv_2mortal(newSVpv(SM_ENCODED_CHARS(fname), 0)));
        SM_FREE_ENCODED(cx, fname);
    } else {
        XPUSHs(sv_2mortal(newSVpv("anonymous", 0)));
    }

    /* Push arguments */
    for (i = 0; i < argc; i++) {
        JS::RootedString argStr(cx, JS::ToString(cx, args[i]));
        if (argStr) {
            EncodedString encoded = EncodeString(cx, argStr);
            XPUSHs(sv_2mortal(newSVpv(SM_ENCODED_CHARS(encoded), 0)));
            SM_FREE_ENCODED(cx, encoded);
        } else {
            XPUSHs(sv_2mortal(newSVpv("", 0)));
        }
    }

    PUTBACK;
    count = call_pv("JavaScript::SpiderMonkey::function_dispatcher", G_SCALAR);
    SPAGAIN;

    if (count > 0) {
        sv = POPs;
        if (SvROK(sv)) {
            JSObject *retobj = INT2PTR(JSObject *, SvIV(SvRV(sv)));
            args.rval().setObject(*retobj);
        }
        else if (SvIOK(sv)) {
            n_jnum = SvIV(sv);
            args.rval().setInt32(n_jnum);
        } else if (SvNOK(sv)) {
            n_jdbl = SvNV(sv);
            args.rval().setDouble(n_jdbl);
        } else if (SvPOK(sv)) {
            n_jstr = SvPV(sv, PL_na);
            JSString *jsstr = JS_NewStringCopyZ(cx, n_jstr);
            if (jsstr)
                args.rval().setString(jsstr);
        }
    }

    PUTBACK;
    FREETMPS;
    LEAVE;

    return true;
}

/* --------------------------------------------------------------------- */
/* Warning reporter - for JS::SetWarningReporter                         */
/* --------------------------------------------------------------------- */
static void
WarningReporter(JSContext *cx, JSErrorReport *report) {
    char msg[400];
    const char *message = report->message().c_str();

    if (report->linebuf()) {
        int i = 0;
        int printed =
            snprintf(msg, sizeof(msg),
                     "Error: %s at line %d: ", message, report->lineno);
        while (printed < (int)sizeof(msg) - 1) {
            if (report->linebuf()[i] == '\n' || report->linebuf()[i] == '\0')
                break;
            msg[printed] = report->linebuf()[i];
            printed++;
            i++;
        }
        msg[printed] = '\0';
    } else {
        snprintf(msg, sizeof(msg),
                 "Error: %s at line %d", message, report->lineno);
    }
    sv_setpv(get_sv("@", TRUE), msg);
}

/* --------------------------------------------------------------------- */
/* Extract error from pending exception                                  */
/* --------------------------------------------------------------------- */
static void
ReportPendingException(JSContext *cx) {
    if (!JS_IsExceptionPending(cx))
        return;

    JS::RootedValue exc(cx);
    if (!JS_GetPendingException(cx, &exc)) {
        JS_ClearPendingException(cx);
        return;
    }
    JS_ClearPendingException(cx);

    /* If the exception is an Error object, extract its message property
     * for a cleaner error string */
    if (exc.isObject()) {
        JS::RootedObject excObj(cx, &exc.toObject());
        JS::RootedValue msgVal(cx);
        if (JS_GetProperty(cx, excObj, "message", &msgVal)) {
            JS::RootedString msgStr(cx, JS::ToString(cx, msgVal));
            if (msgStr) {
                EncodedString msg = EncodeString(cx, msgStr);
                if (SM_ENCODED_CHARS(msg)) {
                    /* Also try to get the line number */
                    JS::RootedValue lineVal(cx);
                    int lineno = 0;
                    if (JS_GetProperty(cx, excObj, "lineNumber", &lineVal) &&
                        lineVal.isInt32()) {
                        lineno = lineVal.toInt32();
                    }
                    char buf[400];
                    if (lineno > 0) {
                        snprintf(buf, sizeof(buf),
                                 "Error: %s at line %d",
                                 SM_ENCODED_CHARS(msg), lineno);
                    } else {
                        snprintf(buf, sizeof(buf), "Error: %s",
                                 SM_ENCODED_CHARS(msg));
                    }
                    sv_setpv(get_sv("@", TRUE), buf);
                    SM_FREE_ENCODED(cx, msg);
                    return;
                }
            }
        }
    }

    /* Fallback: convert exception to string */
    JS::RootedString excStr(cx, JS::ToString(cx, exc));
    if (excStr) {
        EncodedString msg = EncodeString(cx, excStr);
        if (SM_ENCODED_CHARS(msg)) {
            char buf[400];
            snprintf(buf, sizeof(buf), "Error: %s", SM_ENCODED_CHARS(msg));
            sv_setpv(get_sv("@", TRUE), buf);
            SM_FREE_ENCODED(cx, msg);
        }
    }
}

/* --------------------------------------------------------------------- */
static bool
BranchHandler(JSContext *cx) {
/* --------------------------------------------------------------------- */
    PJS_Context* pcx = (PJS_Context*) JS_GetContextPrivate(cx);

    pcx->branch_count++;
    if (pcx->branch_count > pcx->branch_max) {
        return false;
    } else {
        return true;
    }
}


MODULE = JavaScript::SpiderMonkey	PACKAGE = JavaScript::SpiderMonkey
PROTOTYPES: DISABLE

######################################################################
char *
JS_GetImplementationVersion()
######################################################################
    CODE:
    {
        RETVAL = (char *) JS_GetImplementationVersion();
    }
    OUTPUT:
    RETVAL

######################################################################
JSContext *
JS_Init(maxbytes)
        int maxbytes
######################################################################
    PREINIT:
    JSContext *cx;
    CODE:
    {
        /* If a context already exists, destroy it first.
         * mozjs only supports one context at a time. */
        if (active_context) {
            PJS_Context* old_pcx = (PJS_Context*) JS_GetContextPrivate(active_context);
#if MOZJS_MAJOR_VERSION >= 78
            if (old_pcx && old_pcx->old_realm) {
                JS::LeaveRealm(active_context,
                               (JS::Realm*)old_pcx->old_realm);
                old_pcx->old_realm = nullptr;
            }
#endif
            if (old_pcx)
                Safefree(old_pcx);
            JS_DestroyContext(active_context);
            active_context = nullptr;
            prop_store_clear();
        }

        if (!js_engine_initialized) {
            if (!JS_Init()) {
                XSRETURN_UNDEF;
            }
            js_engine_initialized = true;
        }

        cx = JS_NewContext(maxbytes);
        if (!cx) {
            XSRETURN_UNDEF;
        }
        if (!JS::InitSelfHostedCode(cx)) {
            JS_DestroyContext(cx);
            XSRETURN_UNDEF;
        }

        PJS_Context* pcx;
        Newz(1, pcx, 1, PJS_Context);
        JS_SetContextPrivate(cx, (void *)pcx);

        active_context = cx;
        RETVAL = cx;
    }
    OUTPUT:
    RETVAL

######################################################################
int
JS_DestroyContext(cx)
    JSContext *cx;
######################################################################
    CODE:
    {
        /* Guard: only destroy if this is still the active context.
         * It may have been auto-destroyed by a subsequent JS_Init call. */
        if (cx == active_context) {
            PJS_Context* pcx = (PJS_Context*) JS_GetContextPrivate(cx);
#if MOZJS_MAJOR_VERSION >= 78
            if (pcx && pcx->old_realm) {
                JS::LeaveRealm(cx, (JS::Realm*)pcx->old_realm);
                pcx->old_realm = nullptr;
            }
#endif
            if (pcx)
                Safefree(pcx);
            JS_DestroyContext(cx);
            active_context = nullptr;
            prop_store_clear();
        }
        RETVAL = 0;
    }
    OUTPUT:
    RETVAL

######################################################################
JSObject *
JS_NewObject(cx, clasp)
    JSContext * cx
    JSClass   * clasp
######################################################################
    PREINIT:
    JSObject *obj;
    CODE:
    {
        obj = JS_NewObject(cx, clasp);
        if (!obj) {
            XSRETURN_UNDEF;
        }
        RETVAL = obj;
    }
    OUTPUT:
    RETVAL

######################################################################
JSObject *
JS_NewGlobalObject(cx, clasp)
    JSContext * cx
    JSClass   * clasp
######################################################################
    PREINIT:
    JSObject *obj;
    CODE:
    {
#if MOZJS_MAJOR_VERSION >= 78
        JS::RealmOptions options;
        obj = JS_NewGlobalObject(cx, clasp, nullptr,
                                 JS::FireOnNewGlobalHook, options);
        if (!obj) {
            XSRETURN_UNDEF;
        }
        /* Enter the realm of the global object */
        PJS_Context *pcx = (PJS_Context*) JS_GetContextPrivate(cx);
        pcx->old_realm = JS::EnterRealm(cx, obj);
#else
        JS::CompartmentOptions options;
        obj = JS_NewGlobalObject(cx, clasp, nullptr,
                                 JS::FireOnNewGlobalHook, options);
        if (!obj) {
            XSRETURN_UNDEF;
        }
        /* Enter the compartment of the global object */
        JS_EnterCompartment(cx, obj);
#endif
        RETVAL = obj;
    }
    OUTPUT:
    RETVAL

######################################################################
JSClass *
JS_GlobalClass()
######################################################################
    PREINIT:
    JSClass *gc;
    CODE:
    {
        gc = &global_class;
        RETVAL = gc;
    }
    OUTPUT:
    RETVAL

######################################################################
int
JS_EvaluateScript(cx, gobj, script, length, filename, lineno)
    JSContext  * cx
    JSObject   * gobj
    char       * script
    int          length
    char       * filename
    int          lineno
######################################################################
    PREINIT:
    bool rc;
    CODE:
    {
        JS::CompileOptions opts(cx);
        opts.setFileAndLine(filename, lineno);

        JS::RootedValue rval(cx);
#if MOZJS_MAJOR_VERSION >= 78
        JS::SourceText<mozilla::Utf8Unit> srcBuf;
        if (!srcBuf.init(cx, script, (size_t)length,
                         JS::SourceOwnership::Borrowed))
            XSRETURN_UNDEF;
        rc = JS::Evaluate(cx, opts, srcBuf, &rval);
#else
        rc = JS::Evaluate(cx, opts, script, (size_t)length, &rval);
#endif

        if (!rc) {
            ReportPendingException(cx);
            XSRETURN_UNDEF;
        }
        RETVAL = 1;
    }
    OUTPUT:
    RETVAL

######################################################################
int
JS_InitStandardClasses(cx, gobj)
    JSContext  * cx
    JSObject   * gobj
######################################################################
    PREINIT:
    bool rc;
    CODE:
    {
#if MOZJS_MAJOR_VERSION >= 78
        rc = JS::InitRealmStandardClasses(cx);
#else
        JS::RootedObject rgobj(cx, gobj);
        rc = JS_InitStandardClasses(cx, rgobj);
#endif
        if (!rc) {
            XSRETURN_UNDEF;
        }
        RETVAL = 1;
    }
    OUTPUT:
    RETVAL

######################################################################
int
JS_DefineFunction(cx, obj, name, nargs, flags)
    JSContext  * cx
    JSObject   * obj
    char       * name
    int          nargs
    int          flags
######################################################################
    PREINIT:
    JSFunction *rc;
    CODE:
    {
        JS::RootedObject robj(cx, obj);
        rc = JS_DefineFunction(cx, robj,
             (const char *) name, FunctionDispatcher,
             (unsigned) nargs, (unsigned) flags);
        if (!rc) {
            XSRETURN_UNDEF;
        }
        RETVAL = 1;
    }
    OUTPUT:
    RETVAL

######################################################################
int
JS_SetErrorReporter(cx)
    JSContext  * cx
######################################################################
    CODE:
    {
        JS::SetWarningReporter(cx, WarningReporter);
        RETVAL = 0;
    }
    OUTPUT:
    RETVAL

######################################################################
JSObject *
JS_DefineObject(cx, obj, name, clasp, proto)
    JSContext  * cx
    JSObject   * obj
    char       * name
    JSClass    * clasp
    JSObject   * proto
######################################################################
    PREINIT:
    JSObject *newobj;
    CODE:
    {
        JS::RootedObject robj(cx, obj);
        JS::RootedObject rproto(cx, proto);

        /* Create object with given prototype */
        newobj = JS_NewObjectWithGivenProto(cx, clasp, rproto);
        if (!newobj) {
            XSRETURN_UNDEF;
        }

        /* Define it as a property on the parent object */
        JS::RootedValue val(cx, JS::ObjectValue(*newobj));
        if (!JS_DefineProperty(cx, robj, name, val, JSPROP_ENUMERATE)) {
            XSRETURN_UNDEF;
        }

        RETVAL = newobj;
    }
    OUTPUT:
    RETVAL

######################################################################
int
JS_DefineProperty(cx, obj, name, value)
    JSContext   * cx
    JSObject    * obj
    char        * name
    char        * value
######################################################################
    PREINIT:
    bool rc;
    CODE:
    {
        JS::RootedObject robj(cx, obj);
        JS::RootedString str(cx, JS_NewStringCopyZ(cx, value));
        JS::RootedValue val(cx, JS::StringValue(str));
        rc = JS_DefineProperty(cx, robj, name, val, JSPROP_ENUMERATE);
        RETVAL = (int) rc;
    }
    OUTPUT:
    RETVAL

######################################################################
int
JS_DefinePropertyWithAccessors(cx, obj, name, value)
    JSContext   * cx
    JSObject    * obj
    char        * name
    char        * value
######################################################################
    PREINIT:
    bool rc;
    CODE:
    {
        JS::RootedObject robj(cx, obj);

        /* Store initial value in our property store */
        prop_store_set((void*)obj, name, value);

        /* Define as accessor property with getter/setter interceptors */
#if MOZJS_MAJOR_VERSION >= 78
        /* Use the JSNative overload; getter_native/setter_native retrieve
         * the property name from the callee function created by
         * JS_NewFunction with the property name embedded. */
        JSFunction *getterFn = JS_NewFunction(cx, getter_native, 0, 0, name);
        if (!getterFn) XSRETURN_UNDEF;
        JSFunction *setterFn = JS_NewFunction(cx, setter_native, 1, 0, name);
        if (!setterFn) XSRETURN_UNDEF;
        JS::RootedObject rgetterObj(cx, JS_GetFunctionObject(getterFn));
        JS::RootedObject rsetterObj(cx, JS_GetFunctionObject(setterFn));
        rc = JS_DefineProperty(cx, robj, name, rgetterObj, rsetterObj,
                               JSPROP_ENUMERATE | JSPROP_GETTER | JSPROP_SETTER);
#else
        rc = JS_DefineProperty(cx, robj, name,
                               JS_PROPERTYOP_GETTER(getter_dispatcher),
                               JS_PROPERTYOP_SETTER(setter_dispatcher),
                               JSPROP_ENUMERATE | JSPROP_PROPOP_ACCESSORS);
#endif
        RETVAL = (int) rc;
    }
    OUTPUT:
    RETVAL

######################################################################
void
JS_GetProperty(cx, obj, name)
    JSContext   * cx
    JSObject    * obj
    char        * name
######################################################################
    PREINIT:
    bool rc;
    SV   *sv = sv_newmortal();
    PPCODE:
    {
        JS::RootedObject robj(cx, obj);
        JS::RootedValue vp(cx);
        rc = JS_GetProperty(cx, robj, name, &vp);
        if (rc) {
            JS::RootedString str(cx, JS::ToString(cx, vp));
            if (str) {
                EncodedString encoded = EncodeString(cx, str);
                if (SM_ENCODED_CHARS(encoded)) {
                    if (strcmp(SM_ENCODED_CHARS(encoded), "undefined") == 0) {
                        sv = &PL_sv_undef;
                    } else {
                        sv_setpv(sv, SM_ENCODED_CHARS(encoded));
                    }
                    SM_FREE_ENCODED(cx, encoded);
                } else {
                    sv = &PL_sv_undef;
                }
            } else {
                sv = &PL_sv_undef;
            }
        } else {
            sv = &PL_sv_undef;
        }
        XPUSHs(sv);
    }

######################################################################
JSObject *
JS_NewArrayObject(cx)
    JSContext  * cx
######################################################################
    PREINIT:
    JSObject *rc;
    CODE:
    {
#if MOZJS_MAJOR_VERSION >= 78
        rc = JS::NewArrayObject(cx, (size_t)0);
#else
        rc = JS_NewArrayObject(cx, (size_t)0);
#endif
        RETVAL = rc;
    }
    OUTPUT:
    RETVAL

######################################################################
int
JS_SetElement(cx, obj, idx, valptr)
    JSContext  *cx
    JSObject   *obj
    int         idx
    char       *valptr
######################################################################
    PREINIT:
    bool rc;
    CODE:
    {
        JS::RootedObject robj(cx, obj);
        JS::RootedString str(cx, JS_NewStringCopyZ(cx, valptr));
        JS::RootedValue val(cx, JS::StringValue(str));
        rc = JS_SetElement(cx, robj, (uint32_t)idx, val);
        RETVAL = rc ? 1 : 0;
    }
    OUTPUT:
    RETVAL

######################################################################
int
JS_SetElementAsObject(cx, obj, idx, elobj)
    JSContext  *cx
    JSObject   *obj
    int         idx
    JSObject   *elobj
######################################################################
    PREINIT:
    bool rc;
    CODE:
    {
        JS::RootedObject robj(cx, obj);
        JS::RootedValue val(cx, JS::ObjectValue(*elobj));
        rc = JS_SetElement(cx, robj, (uint32_t)idx, val);
        RETVAL = rc ? 1 : 0;
    }
    OUTPUT:
    RETVAL

######################################################################
void
JS_GetElement(cx, obj, idx)
    JSContext  *cx
    JSObject   *obj
    int         idx
######################################################################
    PREINIT:
    bool rc;
    SV   *sv = sv_newmortal();
    PPCODE:
    {
        JS::RootedObject robj(cx, obj);
        JS::RootedValue vp(cx);
        rc = JS_GetElement(cx, robj, (uint32_t)idx, &vp);
        if (rc) {
            JS::RootedString str(cx, JS::ToString(cx, vp));
            if (str) {
                EncodedString encoded = EncodeString(cx, str);
                if (SM_ENCODED_CHARS(encoded)) {
                    if (strcmp(SM_ENCODED_CHARS(encoded), "undefined") == 0) {
                        sv = &PL_sv_undef;
                    } else {
                        sv_setpv(sv, SM_ENCODED_CHARS(encoded));
                    }
                    SM_FREE_ENCODED(cx, encoded);
                } else {
                    sv = &PL_sv_undef;
                }
            } else {
                sv = &PL_sv_undef;
            }
        } else {
            sv = &PL_sv_undef;
        }
        XPUSHs(sv);
    }

######################################################################
JSClass *
JS_GetClass(obj)
    JSObject  * obj
######################################################################
    PREINIT:
    const JSClass *rc;
    CODE:
    {
        rc = JS_GetClass(obj);
        RETVAL = (JSClass *)rc;
    }
    OUTPUT:
    RETVAL


######################################################################
void
JS_SetMaxBranchOperations(cx, max_branch_operations)
    JSContext  *cx
    int         max_branch_operations
######################################################################
    CODE:
    {
        PJS_Context* pcx = (PJS_Context *) JS_GetContextPrivate(cx);
        pcx->branch_count = 0;
        pcx->branch_max = max_branch_operations;
        JS_AddInterruptCallback(cx, BranchHandler);
    }
    OUTPUT:


######################################################################
