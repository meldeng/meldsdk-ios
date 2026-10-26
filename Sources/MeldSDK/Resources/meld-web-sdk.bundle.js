/**
 * Meld SDK — proof of concept.
 *
 * One entry point: Meld.mount(order, hostElement, handlers) -> MeldWidgetHandle.
 * The order is the HeadlessOrderOnrampResponse from POST /crypto/order/headless/onramp,
 * passed verbatim; dispatch is on its declared headlessPresentation (or, for stored orders
 * without one, on (paymentMethodType, renderMode)) via the ADAPTERS registry below — adding
 * a provider is a new registry entry, never a public-API change.
 *
 * Scope: Mercuryo cards (embed.2.1.js + mercuryoWidget.run()), Uphold cards (two-step
 * capture -> authorize via the vendored PaymentWidget), and Banxa cards and Apple Pay
 * (Banxa's own <banxa-primer-checkout> web component, loaded as an ES module and driven
 * by the order's SDK token — no provider URL involved; the same component and token serve
 * both surfaces, and only its payment-methods attribute differs), Coinbase Apple Pay (the
 * order's hosted payment link in a visible iframe), and Stripe cards and Apple Pay (Stripe's
 * crypto onramp runtime, continued through the order's payment actions), and Coinme cards
 * (Coinme's vendored Vault and Risk SDKs, paid through the order's payment actions). Every
 * other combination — bank transfers, other card render modes, undeclared protocols — is
 * rejected with a clear error; support lands by adding a registry entry.
 *
 * Most adapters select on (paymentMethodType, renderMode) plus the widget host. Banxa
 * has no widget host, so it selects on payload.serviceProvider — which is why matches()
 * also receives the order.
 *
 * CENTRAL INVARIANT: this SDK is a container manager and event relay. It never
 * renders card input, never reads or transports PAN/CVC, and never reaches into the
 * provider's cross-origin iframe. No function below accepts or returns payment data.
 * The forms the SDK draws itself are Stripe's: the identity step (name, date of birth, SSN,
 * address), Link registration (name, phone) and the document-check prompt. Their values go
 * straight to Stripe and are never logged, stored, sent to Meld or passed to a callback.
 * Coinme's card form is Coinme Vault's secure fields; the SDK draws only the saved-card picker
 * and the billing state input, whose value goes only to Coinme's card submit.
 */

/* prettier-ignore */
/* eslint-disable */
// ─────────────────────────────────────────────────────────────────────────────
// VENDORED: Uphold payment-widget SDK — installs globalThis.MeldUpholdWidget.PaymentWidget.
// INLINED into this file (rather than loaded via a runtime <script src>) so the widget SHIPS
// WITH and LOADS WITH @meldcrypto/sdk in every consumption mode (bundler, CJS, or raw <script>).
// The previous bare relative script load ('uphold-payment-widget.bundle.js') never resolved for
// integrators (404 → PROVIDER_SCRIPT_LOAD_FAILED). Self-contained minified IIFE; only touches
// window/globalThis. Provenance: Uphold enterprise payment-widget build (see meldeng/meldsdk
// history). Do NOT hand-edit — replace the whole IIFE on update. (Auditability/source-build + SRI
// is tracked separately.)
(()=>{var I=Object.defineProperty;var L=s=>{throw TypeError(s)};var S=(s,i,t)=>i in s?I(s,i,{enumerable:!0,configurable:!0,writable:!0,value:t}):s[i]=t;var g=(s,i,t)=>S(s,typeof i!="symbol"?i+"":i,t),b=(s,i,t)=>i.has(s)||L("Cannot "+t);var r=(s,i,t)=>(b(s,i,"read from private field"),t?t.call(s):i.get(s)),p=(s,i,t)=>i.has(s)?L("Cannot add the same private member more than once"):i instanceof WeakSet?i.add(s):i.set(s,t),y=(s,i,t,e)=>(b(s,i,"write to private field"),e?e.call(s,t):i.set(s,t),t),m=(s,i,t)=>(b(s,i,"access private method"),t);var n=Symbol("log");var W,k,h,l,a,v,c,M,T,f,E,u=class extends(k=EventTarget,W=n,k){constructor(t,e){var o;super();p(this,a);p(this,h);p(this,l,new Map);g(this,"session");g(this,"mountOptions");g(this,"options");g(this,W,{log:(t,...e)=>{m(this,a,E).call(this,"log",t,...e)},warn:(t,...e)=>{m(this,a,E).call(this,"warn",t,...e)}});p(this,f,t=>{let e=new URL(t.origin).origin,o=new URL(this.session.url).origin;if(e!==o){this[n].warn(`[Widget -> Host] ⚠️ Discarding message from '${e}' as it does not match widget origin '${o}' ⚠️`);return}switch(this[n].log("[Widget -> Host] ",t.data),t.data.type){case"force_repaint":{if(!r(this,h))break;r(this,h).style.opacity="0.99",setTimeout(()=>{r(this,h)&&(r(this,h).style.opacity="1")},0);break}case"load":{let d={...this.session,options:this.options,type:"init"};m(this,a,M).call(this,d),this[n].log("[Host -> Widget] ",d);break}case"complete":{m(this,a,c).call(this,"complete",t.data);break}case"cancel":{m(this,a,c).call(this,"cancel");break}case"error":{m(this,a,c).call(this,"error",t.data);break}case"ready":{m(this,a,c).call(this,"ready");break}default:break}});this.session=t,this.options=e,(o=this.options)!=null&&o.debug&&this[n].log("Debug mode is enabled.")}on(t,e){this.addEventListener(t,e),r(this,l).has(t)||r(this,l).set(t,[]),r(this,l).get(t).push(e),this[n].log(`Added listener for event: '${t}'.`)}off(t,e){if(this.removeEventListener(t,e),r(this,l).has(t)){let o=r(this,l).get(t).filter(d=>d!==e);o.length>0?r(this,l).set(t,o):r(this,l).delete(t)}this[n].log(`Removed listener for event: '${t}'.`)}mountIframe(t,e){if(this[n].log("Validating element and initializing iframe mounting."),!t||!(t instanceof HTMLElement))throw new TypeError("Type of 'element' parameter is invalid");this.mountOptions=e;try{this[n].log("Starting widget event listener."),m(this,a,T).call(this),this[n].log("Creating and appending iframe to the DOM."),m(this,a,v).call(this,t),this[n].log("Widget successfully mounted.")}catch(o){throw this[n].log("Error occurred while mounting the widget in iframe: ",o),this.unmount(),new Error("Unable to mount widget: ",{cause:o})}}unmount(){window.removeEventListener("message",r(this,f)),r(this,l).forEach((t,e)=>{t.forEach(o=>this.removeEventListener(e,o))}),r(this,l).clear(),r(this,h)&&(r(this,h).remove(),y(this,h,void 0))}};h=new WeakMap,l=new WeakMap,a=new WeakSet,v=function(t){var d,x;let e=document.createElement("iframe"),o=new URL(this.session.url);(x=(d=this.options)==null?void 0:d.theme)!=null&&x.appearance&&o.searchParams.set("theme_appearance",this.options.theme.appearance),e.setAttribute("src",o.toString()),e.setAttribute("allow","camera *; clipboard-write *; clipboard-read *"),e.style.width="100%",e.style.height="100%",e.style.border="none",t.appendChild(e),y(this,h,e)},c=function(t,e){this[n].log(`'${t}' event raised. Details: `,e),this.dispatchEvent(new CustomEvent(t,{detail:e}))},M=function(t){var e,o;(o=(e=r(this,h))==null?void 0:e.contentWindow)==null||o.postMessage(t,new URL(this.session.url).origin)},T=function(){window.addEventListener("message",r(this,f))},f=new WeakMap,E=function(t,...e){var o;(o=this.options)!=null&&o.debug&&console[t](`[${this.constructor.name}] `,...e)};var w=class extends u{constructor(i,t){super(i,t),this[n].log("Initialized payment widget. session: ",i," options: ",t)}mountIframe(i,t){super.mountIframe(i,t)}on(i,t){super.on(i,t)}off(i,t){super.off(i,t)}unmount(){super.unmount()}};globalThis.MeldUpholdWidget={PaymentWidget:w};})();
/* eslint-enable */
// ─── END VENDORED Uphold payment widget ──────────────────────────────────────

// Coinme's web SDKs, bundled by sdk/coinme-vendor.js: installs globalThis.MeldCoinmeVendor,
// whose load() evaluates them on first call. Packages:
//   @coinme-security/vault-sdk-js 1.2.0
//   @coinme-security/risk-sdk-js 1.1.1
// The Coinme SDKs are © Coinme Inc. 2026, under the SDK License Agreement in each package.
globalThis.MeldCoinmeVendor=(function(){var sdk;return{load:function(){if(!sdk){var coinme=(()=>{var hv=Object.create;var ie=Object.defineProperty;var gv=Object.getOwnPropertyDescriptor;var yv=Object.getOwnPropertyNames;var bv=Object.getPrototypeOf,wv=Object.prototype.hasOwnProperty;var l=(r,e)=>()=>(e||r((e={exports:{}}).exports,e),e.exports),Sv=(r,e)=>{for(var t in e)ie(r,t,{get:e[t],enumerable:!0})},fi=(r,e,t,n)=>{if(e&&typeof e=="object"||typeof e=="function")for(let i of yv(e))!wv.call(r,i)&&i!==t&&ie(r,i,{get:()=>e[i],enumerable:!(n=gv(e,i))||n.enumerable});return r};var G=(r,e,t)=>(t=r!=null?hv(bv(r)):{},fi(e||!r||!r.__esModule?ie(t,"default",{value:r,enumerable:!0}):t,r)),Ev=r=>fi(ie({},"__esModule",{value:!0}),r);var I=l((it,di)=>{"use strict";var Ar=function(r){return r&&r.Math===Math&&r};di.exports=Ar(typeof globalThis=="object"&&globalThis)||Ar(typeof window=="object"&&window)||Ar(typeof self=="object"&&self)||Ar(typeof global=="object"&&global)||Ar(typeof it=="object"&&it)||function(){return this}()||Function("return this")()});var sr=l((FS,pi)=>{"use strict";pi.exports=!1});var ae=l((VS,hi)=>{"use strict";var mi=I(),Iv=Object.defineProperty;hi.exports=function(r,e){try{Iv(mi,r,{value:e,configurable:!0,writable:!0})}catch{mi[r]=e}return e}});var oe=l((GS,bi)=>{"use strict";var qv=sr(),Cv=I(),xv=ae(),gi="__core-js_shared__",yi=bi.exports=Cv[gi]||xv(gi,{});(yi.versions||(yi.versions=[])).push({version:"3.51.0",mode:qv?"pure":"global",copyright:"\xA9 2013\u20132025 Denis Pushkarev (zloirock.ru), 2025\u20132026 CoreJS Company (core-js.io). All rights reserved.",license:"https://github.com/zloirock/core-js/blob/v3.51.0/LICENSE",source:"https://github.com/zloirock/core-js"})});var ue=l((WS,Si)=>{"use strict";var wi=oe(),Tv=Object.create||Object;Si.exports=function(r,e){return wi[r]||(wi[r]=e||Tv(null))}});var T=l((BS,Ei)=>{"use strict";Ei.exports=function(r){try{return!!r()}catch{return!0}}});var jr=l((US,Ii)=>{"use strict";var Ov=T();Ii.exports=!Ov(function(){var r=function(){}.bind();return typeof r!="function"||r.hasOwnProperty("prototype")})});var x=l((HS,xi)=>{"use strict";var qi=jr(),Ci=Function.prototype,at=Ci.call,Rv=qi&&Ci.bind.bind(at,at);xi.exports=qi?Rv:function(r){return function(){return at.apply(r,arguments)}}});var _r=l((ZS,Ti)=>{"use strict";Ti.exports=function(r){return r==null}});var dr=l((YS,Oi)=>{"use strict";var Pv=_r(),Lv=TypeError;Oi.exports=function(r){if(Pv(r))throw new Lv("Can't call method on "+r);return r}});var kr=l((XS,Ri)=>{"use strict";var Nv=dr(),Av=Object;Ri.exports=function(r){return Av(Nv(r))}});var $=l(($S,Pi)=>{"use strict";var jv=x(),_v=kr(),kv=jv({}.hasOwnProperty);Pi.exports=Object.hasOwn||function(e,t){return kv(_v(e),t)}});var ot=l((zS,Li)=>{"use strict";var Dv=x(),Mv=0,Fv=Math.random(),Vv=Dv(1.1.toString);Li.exports=function(r){return"Symbol("+(r===void 0?"":r)+")_"+Vv(++Mv+Fv,36)}});var pr=l((JS,ji)=>{"use strict";var Gv=I(),Ni=Gv.navigator,Ai=Ni&&Ni.userAgent;ji.exports=Ai?String(Ai):""});var ce=l((KS,Vi)=>{"use strict";var Fi=I(),ut=pr(),_i=Fi.process,ki=Fi.Deno,Di=_i&&_i.versions||ki&&ki.version,Mi=Di&&Di.v8,W,se;Mi&&(W=Mi.split("."),se=W[0]>0&&W[0]<4?1:+(W[0]+W[1]));!se&&ut&&(W=ut.match(/Edge\/(\d+)/),(!W||W[1]>=74)&&(W=ut.match(/Chrome\/(\d+)/),W&&(se=+W[1])));Vi.exports=se});var st=l((QS,Wi)=>{"use strict";var Gi=ce(),Wv=T(),Bv=I(),Uv=Bv.String;Wi.exports=!!Object.getOwnPropertySymbols&&!Wv(function(){var r=Symbol("symbol detection");return!Uv(r)||!(Object(r)instanceof Symbol)||!Symbol.sham&&Gi&&Gi<41})});var ct=l((rE,Bi)=>{"use strict";var Hv=st();Bi.exports=Hv&&!Symbol.sham&&typeof Symbol.iterator=="symbol"});var L=l((eE,Hi)=>{"use strict";var Zv=I(),Yv=ue(),Ui=$(),Xv=ot(),$v=st(),zv=ct(),mr=Zv.Symbol,lt=Yv("wks"),Jv=zv?mr.for||mr:mr&&mr.withoutSetter||Xv;Hi.exports=function(r){return Ui(lt,r)||(lt[r]=$v&&Ui(mr,r)?mr[r]:Jv("Symbol."+r)),lt[r]}});var le=l((tE,Yi)=>{"use strict";var Kv=L(),Qv=Kv("toStringTag"),Zi={};Zi[Qv]="z";Yi.exports=String(Zi)==="[object z]"});var O=l((nE,Xi)=>{"use strict";var vt=typeof document=="object"&&document.all;Xi.exports=typeof vt>"u"&&vt!==void 0?function(r){return typeof r=="function"||r===vt}:function(r){return typeof r=="function"}});var _=l((iE,$i)=>{"use strict";var rf=T();$i.exports=!rf(function(){return Object.defineProperty({},1,{get:function(){return 7}})[1]!==7})});var M=l((aE,zi)=>{"use strict";var ef=O();zi.exports=function(r){return typeof r=="object"?r!==null:ef(r)}});var ve=l((oE,Ki)=>{"use strict";var tf=I(),Ji=M(),ft=tf.document,nf=Ji(ft)&&Ji(ft.createElement);Ki.exports=function(r){return nf?ft.createElement(r):{}}});var dt=l((uE,Qi)=>{"use strict";var af=_(),of=T(),uf=ve();Qi.exports=!af&&!of(function(){return Object.defineProperty(uf("div"),"a",{get:function(){return 7}}).a!==7})});var pt=l((sE,ra)=>{"use strict";var sf=_(),cf=T();ra.exports=sf&&cf(function(){return Object.defineProperty(function(){},"prototype",{value:42,writable:!1}).prototype!==42})});var B=l((cE,ea)=>{"use strict";var lf=M(),vf=String,ff=TypeError;ea.exports=function(r){if(lf(r))return r;throw new ff(vf(r)+" is not an object")}});var F=l((lE,ta)=>{"use strict";var df=jr(),fe=Function.prototype.call;ta.exports=df?fe.bind(fe):function(){return fe.apply(fe,arguments)}});var er=l((vE,na)=>{"use strict";var mt=I(),pf=O(),mf=function(r){return pf(r)?r:void 0};na.exports=function(r,e){return arguments.length<2?mf(mt[r]):mt[r]&&mt[r][e]}});var de=l((fE,ia)=>{"use strict";var hf=x();ia.exports=hf({}.isPrototypeOf)});var ht=l((dE,aa)=>{"use strict";var gf=er(),yf=O(),bf=de(),wf=ct(),Sf=Object;aa.exports=wf?function(r){return typeof r=="symbol"}:function(r){var e=gf("Symbol");return yf(e)&&bf(e.prototype,Sf(r))}});var Dr=l((pE,oa)=>{"use strict";var Ef=String;oa.exports=function(r){try{return Ef(r)}catch{return"Object"}}});var tr=l((mE,ua)=>{"use strict";var If=O(),qf=Dr(),Cf=TypeError;ua.exports=function(r){if(If(r))return r;throw new Cf(qf(r)+" is not a function")}});var pe=l((hE,sa)=>{"use strict";var xf=tr(),Tf=_r();sa.exports=function(r,e){var t=r[e];return Tf(t)?void 0:xf(t)}});var la=l((gE,ca)=>{"use strict";var gt=F(),yt=O(),bt=M(),Of=TypeError;ca.exports=function(r,e){var t,n;if(e==="string"&&yt(t=r.toString)&&!bt(n=gt(t,r))||yt(t=r.valueOf)&&!bt(n=gt(t,r))||e!=="string"&&yt(t=r.toString)&&!bt(n=gt(t,r)))return n;throw new Of("Can't convert object to primitive value")}});var pa=l((yE,da)=>{"use strict";var Rf=F(),va=M(),fa=ht(),Pf=pe(),Lf=la(),Nf=L(),Af=TypeError,jf=Nf("toPrimitive");da.exports=function(r,e){if(!va(r)||fa(r))return r;var t=Pf(r,jf),n;if(t){if(e===void 0&&(e="default"),n=Rf(t,r,e),!va(n)||fa(n))return n;throw new Af("Can't convert object to primitive value")}return e===void 0&&(e="number"),Lf(r,e)}});var wt=l((bE,ma)=>{"use strict";var _f=pa(),kf=ht();ma.exports=function(r){var e=_f(r,"string");return kf(e)?e:e+""}});var nr=l(ga=>{"use strict";var Df=_(),Mf=dt(),Ff=pt(),me=B(),ha=wt(),Vf=TypeError,St=Object.defineProperty,Gf=Object.getOwnPropertyDescriptor,Et="enumerable",It="configurable",qt="writable";ga.f=Df?Ff?function(e,t,n){if(me(e),t=ha(t),me(n),typeof e=="function"&&t==="prototype"&&"value"in n&&qt in n&&!n[qt]){var i=Gf(e,t);i&&i[qt]&&(e[t]=n.value,n={configurable:It in n?n[It]:i[It],enumerable:Et in n?n[Et]:i[Et],writable:!1})}return St(e,t,n)}:St:function(e,t,n){if(me(e),t=ha(t),me(n),Mf)try{return St(e,t,n)}catch{}if("get"in n||"set"in n)throw new Vf("Accessors not supported");return"value"in n&&(e[t]=n.value),e}});var wa=l((SE,ba)=>{"use strict";var Ct=_(),Wf=$(),ya=Function.prototype,Bf=Ct&&Object.getOwnPropertyDescriptor,xt=Wf(ya,"name"),Uf=xt&&function(){}.name==="something",Hf=xt&&(!Ct||Ct&&Bf(ya,"name").configurable);ba.exports={EXISTS:xt,PROPER:Uf,CONFIGURABLE:Hf}});var he=l((EE,Sa)=>{"use strict";var Zf=x(),Yf=O(),Tt=oe(),Xf=Zf(Function.toString);Yf(Tt.inspectSource)||(Tt.inspectSource=function(r){return Xf(r)});Sa.exports=Tt.inspectSource});var qa=l((IE,Ia)=>{"use strict";var $f=I(),zf=O(),Ea=$f.WeakMap;Ia.exports=zf(Ea)&&/native code/.test(String(Ea))});var ge=l((qE,Ca)=>{"use strict";Ca.exports=function(r,e){return{enumerable:!(r&1),configurable:!(r&2),writable:!(r&4),value:e}}});var Ot=l((CE,xa)=>{"use strict";var Jf=_(),Kf=nr(),Qf=ge();xa.exports=Jf?function(r,e,t){return Kf.f(r,e,Qf(1,t))}:function(r,e,t){return r[e]=t,r}});var Rt=l((xE,Oa)=>{"use strict";var rd=ue(),ed=ot(),Ta=rd("keys");Oa.exports=function(r){return Ta[r]||(Ta[r]=ed(r))}});var ye=l((TE,Ra)=>{"use strict";Ra.exports={}});var Se=l((OE,Na)=>{"use strict";var td=qa(),La=I(),nd=M(),id=Ot(),Pt=$(),Lt=oe(),ad=Rt(),od=ye(),Pa="Object already initialized",Nt=La.TypeError,ud=La.WeakMap,be,Mr,we,sd=function(r){return we(r)?Mr(r):be(r,{})},cd=function(r){return function(e){var t;if(!nd(e)||(t=Mr(e)).type!==r)throw new Nt("Incompatible receiver, "+r+" required");return t}};td||Lt.state?(U=Lt.state||(Lt.state=new ud),U.get=U.get,U.has=U.has,U.set=U.set,be=function(r,e){if(U.has(r))throw new Nt(Pa);return e.facade=r,U.set(r,e),e},Mr=function(r){return U.get(r)||{}},we=function(r){return U.has(r)}):(cr=ad("state"),od[cr]=!0,be=function(r,e){if(Pt(r,cr))throw new Nt(Pa);return e.facade=r,id(r,cr,e),e},Mr=function(r){return Pt(r,cr)?r[cr]:{}},we=function(r){return Pt(r,cr)});var U,cr;Na.exports={set:be,get:Mr,has:we,enforce:sd,getterFor:cd}});var _t=l((RE,_a)=>{"use strict";var jt=x(),ld=T(),vd=O(),Ee=$(),At=_(),fd=wa().CONFIGURABLE,dd=he(),ja=Se(),pd=ja.enforce,md=ja.get,Aa=String,Ie=Object.defineProperty,hd=jt("".slice),gd=jt("".replace),yd=jt([].join),bd=At&&!ld(function(){return Ie(function(){},"length",{value:8}).length!==8}),wd=String(String).split("String"),Sd=_a.exports=function(r,e,t){hd(Aa(e),0,7)==="Symbol("&&(e="["+gd(Aa(e),/^Symbol\(([^)]*)\).*$/,"$1")+"]"),t&&t.getter&&(e="get "+e),t&&t.setter&&(e="set "+e),(!Ee(r,"name")||fd&&r.name!==e)&&(At?Ie(r,"name",{value:e,configurable:!0}):r.name=e),bd&&t&&Ee(t,"arity")&&r.length!==t.arity&&Ie(r,"length",{value:t.arity});try{t&&Ee(t,"constructor")&&t.constructor?At&&Ie(r,"prototype",{writable:!1}):r.prototype&&(r.prototype=void 0)}catch{}var n=pd(r);return Ee(n,"source")||(n.source=yd(wd,typeof e=="string"?e:"")),r};Function.prototype.toString=Sd(function(){return vd(this)&&md(this).source||dd(this)},"toString")});var hr=l((PE,ka)=>{"use strict";var Ed=O(),Id=nr(),qd=_t(),Cd=ae();ka.exports=function(r,e,t,n){n||(n={});var i=n.enumerable,a=n.name!==void 0?n.name:e;if(Ed(t)&&qd(t,a,n),n.global)i?r[e]=t:Cd(e,t);else{try{n.unsafe?r[e]&&(i=!0):delete r[e]}catch{}i?r[e]=t:Id.f(r,e,{value:t,enumerable:!1,configurable:!n.nonConfigurable,writable:!n.nonWritable})}return r}});var ir=l((LE,Ma)=>{"use strict";var Da=x(),xd=Da({}.toString),Td=Da("".slice);Ma.exports=function(r){return Td(xd(r),8,-1)}});var Ce=l((NE,Fa)=>{"use strict";var Od=le(),Rd=O(),qe=ir(),Pd=L(),Ld=Pd("toStringTag"),Nd=Object,Ad=qe(function(){return arguments}())==="Arguments",jd=function(r,e){try{return r[e]}catch{}};Fa.exports=Od?qe:function(r){var e,t,n;return r===void 0?"Undefined":r===null?"Null":typeof(t=jd(e=Nd(r),Ld))=="string"?t:Ad?qe(e):(n=qe(e))==="Object"&&Rd(e.callee)?"Arguments":n}});var Ga=l((AE,Va)=>{"use strict";var _d=le(),kd=Ce();Va.exports=_d?{}.toString:function(){return"[object "+kd(this)+"]"}});var Wa=l(()=>{"use strict";var Dd=le(),Md=hr(),Fd=Ga();Dd||Md(Object.prototype,"toString",Fd,{unsafe:!0})});var kt=l(Ha=>{"use strict";var Ba={}.propertyIsEnumerable,Ua=Object.getOwnPropertyDescriptor,Vd=Ua&&!Ba.call({1:2},1);Ha.f=Vd?function(e){var t=Ua(this,e);return!!t&&t.enumerable}:Ba});var xe=l((DE,Za)=>{"use strict";var Gd=x(),Wd=T(),Bd=ir(),Dt=Object,Ud=Gd("".split);Za.exports=Wd(function(){return!Dt("z").propertyIsEnumerable(0)})?function(r){return Bd(r)==="String"?Ud(r,""):Dt(r)}:Dt});var Fr=l((ME,Ya)=>{"use strict";var Hd=xe(),Zd=dr();Ya.exports=function(r){return Hd(Zd(r))}});var Te=l($a=>{"use strict";var Yd=_(),Xd=F(),$d=kt(),zd=ge(),Jd=Fr(),Kd=wt(),Qd=$(),rp=dt(),Xa=Object.getOwnPropertyDescriptor;$a.f=Yd?Xa:function(e,t){if(e=Jd(e),t=Kd(t),rp)try{return Xa(e,t)}catch{}if(Qd(e,t))return zd(!Xd($d.f,e,t),e[t])}});var Ja=l((VE,za)=>{"use strict";var ep=Math.ceil,tp=Math.floor;za.exports=Math.trunc||function(e){var t=+e;return(t>0?tp:ep)(t)}});var Mt=l((GE,Ka)=>{"use strict";var np=Ja();Ka.exports=function(r){var e=+r;return e!==e||e===0?0:np(e)}});var ro=l((WE,Qa)=>{"use strict";var ip=Mt(),ap=Math.max,op=Math.min;Qa.exports=function(r,e){var t=ip(r);return t<0?ap(t+e,0):op(t,e)}});var Ft=l((BE,eo)=>{"use strict";var up=Mt(),sp=Math.min;eo.exports=function(r){var e=up(r);return e>0?sp(e,9007199254740991):0}});var Oe=l((UE,to)=>{"use strict";var cp=Ft();to.exports=function(r){return cp(r.length)}});var ao=l((HE,io)=>{"use strict";var lp=Fr(),vp=ro(),fp=Oe(),no=function(r){return function(e,t,n){var i=lp(e),a=fp(i);if(a===0)return!r&&-1;var o=vp(n,a),u;if(r&&t!==t){for(;a>o;)if(u=i[o++],u!==u)return!0}else for(;a>o;o++)if((r||o in i)&&i[o]===t)return r||o||0;return!r&&-1}};io.exports={includes:no(!0),indexOf:no(!1)}});var Gt=l((ZE,uo)=>{"use strict";var dp=x(),Vt=$(),pp=Fr(),mp=ao().indexOf,hp=ye(),oo=dp([].push);uo.exports=function(r,e){var t=pp(r),n=0,i=[],a;for(a in t)!Vt(hp,a)&&Vt(t,a)&&oo(i,a);for(;e.length>n;)Vt(t,a=e[n++])&&(~mp(i,a)||oo(i,a));return i}});var Re=l((YE,so)=>{"use strict";so.exports=["constructor","hasOwnProperty","isPrototypeOf","propertyIsEnumerable","toLocaleString","toString","valueOf"]});var lo=l(co=>{"use strict";var gp=Gt(),yp=Re(),bp=yp.concat("length","prototype");co.f=Object.getOwnPropertyNames||function(e){return gp(e,bp)}});var Wt=l(vo=>{"use strict";vo.f=Object.getOwnPropertySymbols});var po=l((zE,fo)=>{"use strict";var wp=er(),Sp=x(),Ep=lo(),Ip=Wt(),qp=B(),Cp=Sp([].concat);fo.exports=wp("Reflect","ownKeys")||function(e){var t=Ep.f(qp(e)),n=Ip.f;return n?Cp(t,n(e)):t}});var go=l((JE,ho)=>{"use strict";var mo=$(),xp=po(),Tp=Te(),Op=nr();ho.exports=function(r,e,t){for(var n=xp(e),i=Op.f,a=Tp.f,o=0;o<n.length;o++){var u=n[o];!mo(r,u)&&!(t&&mo(t,u))&&i(r,u,a(e,u))}}});var Bt=l((KE,yo)=>{"use strict";var Rp=T(),Pp=O(),Lp=/#|\.prototype\./,Vr=function(r,e){var t=Ap[Np(r)];return t===_p?!0:t===jp?!1:Pp(e)?Rp(e):!!e},Np=Vr.normalize=function(r){return String(r).replace(Lp,".").toLowerCase()},Ap=Vr.data={},jp=Vr.NATIVE="N",_p=Vr.POLYFILL="P";yo.exports=Vr});var N=l((QE,bo)=>{"use strict";var Pe=I(),kp=Te().f,Dp=Ot(),Mp=hr(),Fp=ae(),Vp=go(),Gp=Bt();bo.exports=function(r,e){var t=r.target,n=r.global,i=r.stat,a,o,u,s,c,f;if(n?o=Pe:i?o=Pe[t]||Fp(t,{}):o=Pe[t]&&Pe[t].prototype,o)for(u in e){if(c=e[u],r.dontCallGetSet?(f=kp(o,u),s=f&&f.value):s=o[u],a=Gp(n?u:t+(i?".":"#")+u,r.forced),!a&&s!==void 0){if(typeof c==typeof s)continue;Vp(c,s)}(r.sham||s&&s.sham)&&Dp(c,"sham",!0),Mp(o,u,c,r)}}});var Ut=l((rI,wo)=>{"use strict";var Gr=I(),Wp=pr(),Bp=ir(),Le=function(r){return Wp.slice(0,r.length)===r};wo.exports=function(){return Le("Bun/")?"BUN":Le("Cloudflare-Workers")?"CLOUDFLARE":Le("Deno/")?"DENO":Le("Node.js/")?"NODE":Gr.Bun&&typeof Bun.version=="string"?"BUN":Gr.Deno&&typeof Deno.version=="object"?"DENO":Bp(Gr.process)==="process"?"NODE":Gr.window&&Gr.document?"BROWSER":"REST"}()});var Ne=l((eI,So)=>{"use strict";var Up=Ut();So.exports=Up==="NODE"});var Io=l((tI,Eo)=>{"use strict";var Hp=I();Eo.exports=Hp});var Co=l((nI,qo)=>{"use strict";var Zp=x(),Yp=tr();qo.exports=function(r,e,t){try{return Zp(Yp(Object.getOwnPropertyDescriptor(r,e)[t]))}catch{}}});var To=l((iI,xo)=>{"use strict";var Xp=M();xo.exports=function(r){return Xp(r)||r===null}});var Ro=l((aI,Oo)=>{"use strict";var $p=To(),zp=String,Jp=TypeError;Oo.exports=function(r){if($p(r))return r;throw new Jp("Can't set "+zp(r)+" as a prototype")}});var Lo=l((oI,Po)=>{"use strict";var Kp=Co(),Qp=M(),rm=dr(),em=Ro();Po.exports=Object.setPrototypeOf||("__proto__"in{}?function(){var r=!1,e={},t;try{t=Kp(Object.prototype,"__proto__","set"),t(e,[]),r=e instanceof Array}catch{}return function(i,a){return rm(i),em(a),Qp(i)&&(r?t(i,a):i.__proto__=a),i}}():void 0)});var jo=l((uI,Ao)=>{"use strict";var tm=nr().f,nm=$(),im=L(),No=im("toStringTag");Ao.exports=function(r,e,t){r&&!t&&(r=r.prototype),r&&!nm(r,No)&&tm(r,No,{configurable:!0,value:e})}});var Do=l((sI,ko)=>{"use strict";var _o=_t(),am=nr();ko.exports=function(r,e,t){return t.get&&_o(t.get,e,{getter:!0}),t.set&&_o(t.set,e,{setter:!0}),am.f(r,e,t)}});var Vo=l((cI,Fo)=>{"use strict";var om=er(),um=Do(),sm=L(),cm=_(),Mo=sm("species");Fo.exports=function(r){var e=om(r);cm&&e&&!e[Mo]&&um(e,Mo,{configurable:!0,get:function(){return this}})}});var Wo=l((lI,Go)=>{"use strict";var lm=de(),vm=TypeError;Go.exports=function(r,e){if(lm(e,r))return r;throw new vm("Incorrect invocation")}});var Zt=l((vI,Yo)=>{"use strict";var fm=x(),dm=T(),Bo=O(),pm=Ce(),mm=er(),hm=he(),Uo=function(){},Ho=mm("Reflect","construct"),Ht=/^\s*(?:class|function)\b/,gm=fm(Ht.exec),ym=!Ht.test(Uo),Wr=function(e){if(!Bo(e))return!1;try{return Ho(Uo,[],e),!0}catch{return!1}},Zo=function(e){if(!Bo(e))return!1;switch(pm(e)){case"AsyncFunction":case"GeneratorFunction":case"AsyncGeneratorFunction":return!1}try{return ym||!!gm(Ht,hm(e))}catch{return!0}};Zo.sham=!0;Yo.exports=!Ho||dm(function(){var r;return Wr(Wr.call)||!Wr(Object)||!Wr(function(){r=!0})||r})?Zo:Wr});var $o=l((fI,Xo)=>{"use strict";var bm=Zt(),wm=Dr(),Sm=TypeError;Xo.exports=function(r){if(bm(r))return r;throw new Sm(wm(r)+" is not a constructor")}});var Ko=l((dI,Jo)=>{"use strict";var zo=B(),Em=$o(),Im=_r(),qm=L(),Cm=qm("species");Jo.exports=function(r,e){var t=zo(r).constructor,n;return t===void 0||Im(n=zo(t)[Cm])?e:Em(n)}});var nu=l((pI,tu)=>{"use strict";var xm=jr(),eu=Function.prototype,Qo=eu.apply,ru=eu.call;tu.exports=typeof Reflect=="object"&&Reflect.apply||(xm?ru.bind(Qo):function(){return ru.apply(Qo,arguments)})});var Yt=l((mI,iu)=>{"use strict";var Tm=ir(),Om=x();iu.exports=function(r){if(Tm(r)==="Function")return Om(r)}});var Br=l((hI,ou)=>{"use strict";var au=Yt(),Rm=tr(),Pm=jr(),Lm=au(au.bind);ou.exports=function(r,e){return Rm(r),e===void 0?r:Pm?Lm(r,e):function(){return r.apply(e,arguments)}}});var Xt=l((gI,uu)=>{"use strict";var Nm=er();uu.exports=Nm("document","documentElement")});var cu=l((yI,su)=>{"use strict";var Am=x();su.exports=Am([].slice)});var vu=l((bI,lu)=>{"use strict";var jm=TypeError;lu.exports=function(r,e){if(r<e)throw new jm("Not enough arguments");return r}});var $t=l((wI,du)=>{"use strict";var fu=pr();du.exports=/ipad|iphone|ipod/i.test(fu)&&/applewebkit/i.test(fu)});var an=l((SI,Eu)=>{"use strict";var k=I(),_m=nu(),km=Br(),pu=O(),Dm=$(),Su=T(),mu=Xt(),Mm=cu(),hu=ve(),Fm=vu(),Vm=$t(),Gm=Ne(),en=k.setImmediate,tn=k.clearImmediate,Wm=k.process,zt=k.Dispatch,Bm=k.Function,gu=k.MessageChannel,Um=k.String,Jt=0,Ur={},yu="onreadystatechange",Hr,lr,Kt,Qt;Su(function(){Hr=k.location});var nn=function(r){if(Dm(Ur,r)){var e=Ur[r];delete Ur[r],e()}},rn=function(r){return function(){nn(r)}},bu=function(r){nn(r.data)},wu=function(r){k.postMessage(Um(r),Hr.protocol+"//"+Hr.host)};(!en||!tn)&&(en=function(e){Fm(arguments.length,1);var t=pu(e)?e:Bm(e),n=Mm(arguments,1);return Ur[++Jt]=function(){_m(t,void 0,n)},lr(Jt),Jt},tn=function(e){delete Ur[e]},Gm?lr=function(r){Wm.nextTick(rn(r))}:zt&&zt.now?lr=function(r){zt.now(rn(r))}:gu&&!Vm?(Kt=new gu,Qt=Kt.port2,Kt.port1.onmessage=bu,lr=km(Qt.postMessage,Qt)):k.addEventListener&&pu(k.postMessage)&&!k.importScripts&&Hr&&Hr.protocol!=="file:"&&!Su(wu)?(lr=wu,k.addEventListener("message",bu,!1)):yu in hu("script")?lr=function(r){mu.appendChild(hu("script"))[yu]=function(){mu.removeChild(this),nn(r)}}:lr=function(r){setTimeout(rn(r),0)});Eu.exports={set:en,clear:tn}});var Cu=l((EI,qu)=>{"use strict";var Iu=I(),Hm=_(),Zm=Object.getOwnPropertyDescriptor;qu.exports=function(r){if(!Hm)return Iu[r];var e=Zm(Iu,r);return e&&e.value}});var on=l((II,Tu)=>{"use strict";var xu=function(){this.head=null,this.tail=null};xu.prototype={add:function(r){var e={item:r,next:null},t=this.tail;t?t.next=e:this.head=e,this.tail=e},get:function(){var r=this.head;if(r){var e=this.head=r.next;return e===null&&(this.tail=null),r.item}}};Tu.exports=xu});var Ru=l((qI,Ou)=>{"use strict";var Ym=pr();Ou.exports=/ipad|iphone|ipod/i.test(Ym)&&typeof Pebble<"u"});var Lu=l((CI,Pu)=>{"use strict";var Xm=pr();Pu.exports=/web0s(?!.*chrome)/i.test(Xm)});var Mu=l((xI,Du)=>{"use strict";var yr=I(),$m=Cu(),Nu=Br(),un=an().set,zm=on(),Jm=$t(),Km=Ru(),Qm=Lu(),sn=Ne(),Au=yr.MutationObserver||yr.WebKitMutationObserver,ju=yr.document,_u=yr.process,Ae=yr.Promise,vn=$m("queueMicrotask"),gr,cn,ln,je,ku;vn||(Zr=new zm,Yr=function(){var r,e;for(sn&&(r=_u.domain)&&r.exit();e=Zr.get();)try{e()}catch(t){throw Zr.head&&gr(),t}r&&r.enter()},!Jm&&!sn&&!Qm&&Au&&ju?(cn=!0,ln=ju.createTextNode(""),new Au(Yr).observe(ln,{characterData:!0}),gr=function(){ln.data=cn=!cn}):!Km&&Ae&&Ae.resolve?(je=Ae.resolve(void 0),je.constructor=Ae,ku=Nu(je.then,je),gr=function(){ku(Yr)}):sn?gr=function(){_u.nextTick(Yr)}:(un=Nu(un,yr),gr=function(){un(Yr)}),vn=function(r){Zr.head||gr(),Zr.add(r)});var Zr,Yr;Du.exports=vn});var Vu=l((TI,Fu)=>{"use strict";Fu.exports=function(r,e){try{arguments.length===1?console.error(r):console.error(r,e)}catch{}}});var _e=l((OI,Gu)=>{"use strict";Gu.exports=function(r){try{return{error:!1,value:r()}}catch(e){return{error:!0,value:e}}}});var br=l((RI,Wu)=>{"use strict";var rh=I();Wu.exports=rh.Promise});var wr=l((PI,Zu)=>{"use strict";var eh=I(),Xr=br(),th=O(),nh=Bt(),ih=he(),ah=L(),Bu=Ut(),oh=sr(),fn=ce(),Uu=Xr&&Xr.prototype,uh=ah("species"),dn=!1,Hu=th(eh.PromiseRejectionEvent),sh=nh("Promise",function(){var r=ih(Xr),e=r!==String(Xr);if(!e&&fn===66||oh&&!(Uu.catch&&Uu.finally))return!0;if(!fn||fn<51||!/native code/.test(r)){var t=new Xr(function(a){a(1)}),n=function(a){a(function(){},function(){})},i=t.constructor={};if(i[uh]=n,dn=t.then(function(){})instanceof n,!dn)return!0}return!e&&(Bu==="BROWSER"||Bu==="DENO")&&!Hu});Zu.exports={CONSTRUCTOR:sh,REJECTION_EVENT:Hu,SUBCLASSING:dn}});var Sr=l((LI,Xu)=>{"use strict";var Yu=tr(),ch=TypeError,lh=function(r){var e,t;this.promise=new r(function(n,i){if(e!==void 0||t!==void 0)throw new ch("Bad Promise constructor");e=n,t=i}),this.resolve=Yu(e),this.reject=Yu(t)};Xu.exports.f=function(r){return new lh(r)}});var ps=l(()=>{"use strict";var vh=N(),fh=sr(),Fe=Ne(),ar=I(),dh=Io(),Cr=F(),$u=hr(),zu=Lo(),ph=jo(),mh=Vo(),hh=tr(),Me=O(),gh=M(),yh=Wo(),bh=Ko(),es=an().set,yn=Mu(),wh=Vu(),Sh=_e(),Eh=on(),ts=Se(),Ve=br(),bn=wr(),ns=Sr(),Ge="Promise",is=bn.CONSTRUCTOR,Ih=bn.REJECTION_EVENT,qh=bn.SUBCLASSING,pn=ts.getterFor(Ge),Ch=ts.set,Er=Ve&&Ve.prototype,vr=Ve,ke=Er,as=ar.TypeError,mn=ar.document,wn=ar.process,hn=ns.f,xh=hn,Th=!!(mn&&mn.createEvent&&ar.dispatchEvent),os="unhandledrejection",Oh="rejectionhandled",Ju=0,us=1,Rh=2,Sn=1,ss=2,De,Ku,cs,Qu,ls=function(r){var e;return gh(r)&&Me(e=r.then)?e:!1},vs=function(r,e){var t=e.value,n=e.state===us,i=n?r.ok:r.fail,a=r.resolve,o=r.reject,u=r.domain,s,c,f;try{i?(n||(e.rejection===ss&&Lh(e),e.rejection=Sn),i===!0?s=t:(u&&u.enter(),s=i(t),u&&(u.exit(),f=!0)),s===r.promise?o(new as("Promise-chain cycle")):(c=ls(s))?Cr(c,s,a,o):a(s)):o(t)}catch(v){u&&!f&&u.exit(),o(v)}},fs=function(r,e){r.notified||(r.notified=!0,yn(function(){for(var t=r.reactions,n;n=t.get();)vs(n,r);r.notified=!1,e&&!r.rejection&&Ph(r)}))},ds=function(r,e,t){var n,i;Th?(n=mn.createEvent("Event"),n.promise=e,n.reason=t,n.initEvent(r,!1,!0),ar.dispatchEvent(n)):n={promise:e,reason:t},!Ih&&(i=ar["on"+r])?i(n):r===os&&wh("Unhandled promise rejection",t)},Ph=function(r){Cr(es,ar,function(){var e=r.facade,t=r.value,n=rs(r),i;if(n&&(i=Sh(function(){Fe?wn.emit("unhandledRejection",t,e):ds(os,e,t)}),r.rejection=Fe||rs(r)?ss:Sn,i.error))throw i.value})},rs=function(r){return r.rejection!==Sn&&!r.parent},Lh=function(r){Cr(es,ar,function(){var e=r.facade;Fe?wn.emit("rejectionHandled",e):ds(Oh,e,r.value)})},Ir=function(r,e,t){return function(n){r(e,n,t)}},qr=function(r,e,t){r.done||(r.done=!0,t&&(r=t),r.value=e,r.state=Rh,fs(r,!0))},gn=function(r,e,t){if(!r.done){r.done=!0,t&&(r=t);try{if(r.facade===e)throw new as("Promise can't be resolved itself");var n=ls(e);n?yn(function(){var i={done:!1};try{Cr(n,e,Ir(gn,i,r),Ir(qr,i,r))}catch(a){qr(i,a,r)}}):(r.value=e,r.state=us,fs(r,!1))}catch(i){qr({done:!1},i,r)}}};if(is&&(vr=function(e){yh(this,ke),hh(e),Cr(De,this);var t=pn(this);try{e(Ir(gn,t),Ir(qr,t))}catch(n){qr(t,n)}},ke=vr.prototype,De=function(e){Ch(this,{type:Ge,done:!1,notified:!1,parent:!1,reactions:new Eh,rejection:!1,state:Ju,value:null})},De.prototype=$u(ke,"then",function(e,t){var n=pn(this),i=hn(bh(this,vr));return n.parent=!0,i.ok=Me(e)?e:!0,i.fail=Me(t)&&t,i.domain=Fe?wn.domain:void 0,n.state===Ju?n.reactions.add(i):yn(function(){vs(i,n)}),i.promise}),Ku=function(){var r=new De,e=pn(r);this.promise=r,this.resolve=Ir(gn,e),this.reject=Ir(qr,e)},ns.f=hn=function(r){return r===vr||r===cs?new Ku(r):xh(r)},!fh&&Me(Ve)&&Er!==Object.prototype)){Qu=Er.then,qh||$u(Er,"then",function(e,t){var n=this;return new vr(function(i,a){Cr(Qu,n,i,a)}).then(e,t)},{unsafe:!0});try{delete Er.constructor}catch{}zu&&zu(Er,ke)}vh({global:!0,constructor:!0,wrap:!0,forced:is},{Promise:vr});cs=dh.Promise;ph(vr,Ge,!1,!0);mh(Ge)});var hs=l((jI,ms)=>{"use strict";ms.exports=Object.create?Object.create(null):{}});var ys=l((_I,gs)=>{"use strict";var Nh=L(),Ah=hs(),jh=Nh("iterator"),_h=Array.prototype;gs.exports=function(r){return r!==void 0&&(Ah.Array===r||_h[jh]===r)}});var En=l((kI,Ss)=>{"use strict";var kh=ir(),Dh=_r(),bs=pe(),Mh=L(),ws=Mh("iterator"),Fh=Array.prototype;Ss.exports=function(r){if(!Dh(r))return bs(r,ws)||bs(r,"@@iterator")||(kh(r)==="Arguments"?Fh[ws]:void 0)}});var Is=l((DI,Es)=>{"use strict";var Vh=F(),Gh=O(),Wh=B(),Bh=Dr(),Uh=En(),Hh=TypeError;Es.exports=function(r,e){var t=arguments.length<2?Uh(r):e;if(Gh(t))return Wh(Vh(t,r));throw new Hh(Bh(r)+" is not iterable")}});var xs=l((MI,Cs)=>{"use strict";var Zh=F(),qs=B(),Yh=pe();Cs.exports=function(r,e,t){var n,i;qs(r);try{if(n=Yh(r,"return"),!n){if(e==="throw")throw t;return t}n=Zh(n,r)}catch(a){i=!0,n=a}if(e==="throw")throw t;if(i)throw n;return qs(n),t}});var In=l((FI,Ps)=>{"use strict";var Xh=Br(),$h=F(),zh=B(),Jh=Dr(),Kh=ys(),Qh=Oe(),Ts=de(),rg=Is(),eg=En(),Os=xs(),tg=TypeError,We=function(r,e){this.stopped=r,this.result=e},Rs=We.prototype;Ps.exports=function(r,e,t){var n=t&&t.that,i=!!(t&&t.AS_ENTRIES),a=!!(t&&t.IS_RECORD),o=!!(t&&t.IS_ITERATOR),u=!!(t&&t.INTERRUPTED),s=Xh(e,n),c,f,v,p,d,m,y,h=function(b){var C=c;return c=void 0,C&&Os(C,"normal"),new We(!0,b)},g=function(b){return i?(zh(b),u?s(b[0],b[1],h):s(b[0],b[1])):u?s(b,h):s(b)};if(a)c=r.iterator;else if(o)c=r;else{if(f=eg(r),!f)throw new tg(Jh(r)+" is not iterable");if(Kh(f)){for(v=0,p=Qh(r);p>v;v++)if(d=g(r[v]),d&&Ts(Rs,d))return d;return new We(!1)}c=rg(r,f)}for(m=a?r.next:c.next;!(y=$h(m,c)).done;){var w=y.value;try{d=g(w)}catch(b){if(c)Os(c,"throw",b);else throw b}if(typeof d=="object"&&d&&Ts(Rs,d))return d}return new We(!1)}});var _s=l((VI,js)=>{"use strict";var ng=L(),Ns=ng("iterator"),As=!1;try{Ls=0,qn={next:function(){return{done:!!Ls++}},return:function(){As=!0}},qn[Ns]=function(){return this},Array.from(qn,function(){throw 2})}catch{}var Ls,qn;js.exports=function(r,e){try{if(!e&&!As)return!1}catch{return!1}var t=!1;try{var n={};n[Ns]=function(){return{next:function(){return{done:t=!0}}}},r(n)}catch{}return t}});var Cn=l((GI,ks)=>{"use strict";var ig=br(),ag=_s(),og=wr().CONSTRUCTOR;ks.exports=og||!ag(function(r){ig.all(r).then(void 0,function(){})})});var Ds=l(()=>{"use strict";var ug=N(),sg=F(),cg=tr(),lg=Sr(),vg=_e(),fg=In(),dg=Cn();ug({target:"Promise",stat:!0,forced:dg},{all:function(e){var t=this,n=lg.f(t),i=n.resolve,a=n.reject,o=vg(function(){var u=cg(t.resolve),s=[],c=0,f=1;fg(e,function(v){var p=c++,d=!1;f++,sg(u,t,v).then(function(m){d||(d=!0,s[p]=m,--f||i(s))},a)}),--f||i(s)});return o.error&&a(o.value),n.promise}})});var Fs=l(()=>{"use strict";var pg=N(),mg=sr(),hg=wr().CONSTRUCTOR,Tn=br(),gg=er(),yg=O(),bg=hr(),Ms=Tn&&Tn.prototype;pg({target:"Promise",proto:!0,forced:hg,real:!0},{catch:function(r){return this.then(void 0,r)}});!mg&&yg(Tn)&&(xn=gg("Promise").prototype.catch,Ms.catch!==xn&&bg(Ms,"catch",xn,{unsafe:!0}));var xn});var Vs=l(()=>{"use strict";var wg=N(),Sg=F(),Eg=tr(),Ig=Sr(),qg=_e(),Cg=In(),xg=Cn();wg({target:"Promise",stat:!0,forced:xg},{race:function(e){var t=this,n=Ig.f(t),i=n.reject,a=qg(function(){var o=Eg(t.resolve);Cg(e,function(u){Sg(o,t,u).then(n.resolve,i)})});return a.error&&i(a.value),n.promise}})});var Gs=l(()=>{"use strict";var Tg=N(),Og=Sr(),Rg=wr().CONSTRUCTOR;Tg({target:"Promise",stat:!0,forced:Rg},{reject:function(e){var t=Og.f(this),n=t.reject;return n(e),t.promise}})});var Bs=l((zI,Ws)=>{"use strict";var Pg=B(),Lg=M(),Ng=Sr();Ws.exports=function(r,e){if(Pg(r),Lg(e)&&e.constructor===r)return e;var t=Ng.f(r),n=t.resolve;return n(e),t.promise}});var Zs=l(()=>{"use strict";var Ag=N(),jg=er(),Us=sr(),_g=br(),Hs=wr().CONSTRUCTOR,kg=Bs(),Dg=jg("Promise"),Mg=Us&&!Hs;Ag({target:"Promise",stat:!0,forced:Us||Hs},{resolve:function(e){return kg(Mg&&this===Dg?_g:this,e)}})});var Ys=l(()=>{"use strict";ps();Ds();Fs();Vs();Gs();Zs()});var $s=l(()=>{"use strict";var Fg=N(),Vg=x(),Xs=Date,Gg=Vg(Xs.prototype.getTime);Fg({target:"Date",stat:!0},{now:function(){return Gg(new Xs)}})});var Qs=l(()=>{"use strict";var Js=x(),Wg=hr(),On=Date.prototype,zs="Invalid Date",Ks="toString",Bg=Js(On[Ks]),Ug=Js(On.getTime);String(new Date(NaN))!==zs&&Wg(On,Ks,function(){var e=Ug(this);return e===e?Bg(this):zs})});var Be=l((a1,rc)=>{"use strict";var Hg=Gt(),Zg=Re();rc.exports=Object.keys||function(e){return Hg(e,Zg)}});var ic=l((o1,nc)=>{"use strict";var ec=_(),Yg=x(),Xg=F(),$g=T(),Rn=Be(),zg=Wt(),Jg=kt(),Kg=kr(),Qg=xe(),xr=Object.assign,tc=Object.defineProperty,ry=Yg([].concat);nc.exports=!xr||$g(function(){if(ec&&xr({b:1},xr(tc({},"a",{enumerable:!0,get:function(){tc(this,"b",{value:3,enumerable:!1})}}),{b:2})).b!==1)return!0;var r={},e={},t=Symbol("assign detection"),n="abcdefghijklmnopqrst";return r[t]=7,n.split("").forEach(function(i){e[i]=i}),xr({},r)[t]!==7||Rn(xr({},e)).join("")!==n})?function(e,t){for(var n=Kg(e),i=arguments.length,a=1,o=zg.f,u=Jg.f;i>a;)for(var s=Qg(arguments[a++]),c=o?ry(Rn(s),o(s)):Rn(s),f=c.length,v=0,p;f>v;)p=c[v++],(!ec||Xg(u,s,p))&&(n[p]=s[p]);return n}:xr});var oc=l(()=>{"use strict";var ey=N(),ac=ic();ey({target:"Object",stat:!0,arity:2,forced:Object.assign!==ac},{assign:ac})});var $r=l((w1,lc)=>{"use strict";var oy=Ce(),uy=String;lc.exports=function(r){if(oy(r)==="Symbol")throw new TypeError("Cannot convert a Symbol value to a string");return uy(r)}});var fc=l((S1,vc)=>{"use strict";var sy=B();vc.exports=function(){var r=sy(this),e="";return r.hasIndices&&(e+="d"),r.global&&(e+="g"),r.ignoreCase&&(e+="i"),r.multiline&&(e+="m"),r.dotAll&&(e+="s"),r.unicode&&(e+="u"),r.unicodeSets&&(e+="v"),r.sticky&&(e+="y"),e}});var pc=l((E1,dc)=>{"use strict";var Nn=T(),cy=I(),An=cy.RegExp,jn=Nn(function(){var r=An("a","y");return r.lastIndex=2,r.exec("abcd")!==null}),ly=jn||Nn(function(){return!An("a","y").sticky}),vy=jn||Nn(function(){var r=An("^r","gy");return r.lastIndex=2,r.exec("str")!==null});dc.exports={BROKEN_CARET:vy,MISSED_STICKY:ly,UNSUPPORTED_Y:jn}});var hc=l(mc=>{"use strict";var fy=_(),dy=pt(),py=nr(),my=B(),hy=Fr(),gy=Be();mc.f=fy&&!dy?Object.defineProperties:function(e,t){my(e);for(var n=hy(t),i=gy(t),a=i.length,o=0,u;a>o;)py.f(e,u=i[o++],n[u]);return e}});var qc=l((q1,Ic)=>{"use strict";var yy=B(),by=hc(),gc=Re(),wy=ye(),Sy=Xt(),Ey=ve(),Iy=Rt(),yc=">",bc="<",kn="prototype",Dn="script",Sc=Iy("IE_PROTO"),_n=function(){},Ec=function(r){return bc+Dn+yc+r+bc+"/"+Dn+yc},wc=function(r){r.write(Ec("")),r.close();var e=r.parentWindow.Object;return r=null,e},qy=function(){var r=Ey("iframe"),e="java"+Dn+":",t;return r.style.display="none",Sy.appendChild(r),r.src=String(e),t=r.contentWindow.document,t.open(),t.write(Ec("document.F=Object")),t.close(),t.F},Ze,Ye=function(){try{Ze=new ActiveXObject("htmlfile")}catch{}Ye=typeof document<"u"?document.domain&&Ze?wc(Ze):qy():wc(Ze);for(var r=gc.length;r--;)delete Ye[kn][gc[r]];return Ye()};wy[Sc]=!0;Ic.exports=Object.create||function(e,t){var n;return e!==null?(_n[kn]=yy(e),n=new _n,_n[kn]=null,n[Sc]=e):n=Ye(),t===void 0?n:by.f(n,t)}});var xc=l((C1,Cc)=>{"use strict";var Cy=T(),xy=I(),Ty=xy.RegExp;Cc.exports=Cy(function(){var r=Ty(".","s");return!(r.dotAll&&r.test(`
`)&&r.flags==="s")})});var Oc=l((x1,Tc)=>{"use strict";var Oy=T(),Ry=I(),Py=Ry.RegExp;Tc.exports=Oy(function(){var r=Py("(?<a>b)","g");return r.exec("b").groups.a!=="b"||"b".replace(r,"$<a>c")!=="bc"})});var Ac=l((T1,Nc)=>{"use strict";var Tr=F(),$e=x(),Ly=$r(),Ny=fc(),Ay=pc(),jy=ue(),_y=qc(),ky=Se().get,Dy=xc(),My=Oc(),Fy=jy("native-string-replace",String.prototype.replace),Xe=RegExp.prototype.exec,Mn=Xe,Vy=$e("".charAt),Gy=$e("".indexOf),Wy=$e("".replace),Rc=$e("".slice),Fn=function(){var r=/a/,e=/b*/g;return Tr(Xe,r,"a"),Tr(Xe,e,"a"),r.lastIndex!==0||e.lastIndex!==0}(),Lc=Ay.BROKEN_CARET,Vn=/()??/.exec("")[1]!==void 0,By=Fn||Vn||Lc||Dy||My,Pc=function(r,e){for(var t=r.groups=_y(null),n=0;n<e.length;n++){var i=e[n];t[i[0]]=r[i[1]]}};By&&(Mn=function(e){var t=this,n=ky(t),i=Ly(e),a=n.raw,o,u,s;if(a)return a.lastIndex=t.lastIndex,o=Tr(Mn,a,i),t.lastIndex=a.lastIndex,o&&n.groups&&Pc(o,n.groups),o;var c=n.groups,f=Lc&&t.sticky,v=Tr(Ny,t),p=t.source,d=0,m=i;if(f){v=Wy(v,"y",""),Gy(v,"g")===-1&&(v+="g"),m=Rc(i,t.lastIndex);var y=t.lastIndex>0&&Vy(i,t.lastIndex-1);t.lastIndex>0&&(!t.multiline||t.multiline&&y!==`
`&&y!=="\r"&&y!=="\u2028"&&y!=="\u2029")&&(p="(?: (?:"+p+"))",m=" "+m,d++),u=new RegExp("^(?:"+p+")",v)}Vn&&(u=new RegExp("^"+p+"$(?!\\s)",v)),Fn&&(s=t.lastIndex);var h=Tr(Xe,f?u:t,m);return f?h?(h.input=i,h[0]=Rc(h[0],d),h.index=t.lastIndex,t.lastIndex+=h[0].length):t.lastIndex=0:Fn&&h&&(t.lastIndex=t.global?h.index+h[0].length:s),Vn&&h&&h.length>1&&Tr(Fy,h[0],u,function(){for(var g=1;g<arguments.length-2;g++)arguments[g]===void 0&&(h[g]=void 0)}),h&&c&&Pc(h,c),h});Nc.exports=Mn});var _c=l(()=>{"use strict";var Uy=N(),jc=Ac();Uy({target:"RegExp",proto:!0,forced:/./.exec!==jc},{exec:jc})});var Dc=l((P1,kc)=>{"use strict";var Hy=M(),Zy=ir(),Yy=L(),Xy=Yy("match");kc.exports=function(r){var e;return Hy(r)&&((e=r[Xy])!==void 0?!!e:Zy(r)==="RegExp")}});var Fc=l((L1,Mc)=>{"use strict";var $y=Dc(),zy=TypeError;Mc.exports=function(r){if($y(r))throw new zy("The method doesn't accept regular expressions");return r}});var Gc=l((N1,Vc)=>{"use strict";var Jy=L(),Ky=Jy("match");Vc.exports=function(r){var e=/./;try{"/./"[r](e)}catch{try{return e[Ky]=!1,"/./"[r](e)}catch{}}return!1}});var Uc=l(()=>{"use strict";var Qy=N(),r0=Yt(),e0=Te().f,t0=Ft(),Wc=$r(),n0=Fc(),i0=dr(),a0=Gc(),o0=sr(),u0=r0("".slice),s0=Math.min,Bc=a0("startsWith"),c0=!o0&&!Bc&&!!function(){var r=e0(String.prototype,"startsWith");return r&&!r.writable}();Qy({target:"String",proto:!0,forced:!c0&&!Bc},{startsWith:function(e){var t=Wc(i0(this));n0(e);var n=Wc(e),i=t0(s0(arguments.length>1?arguments[1]:void 0,t.length));return u0(t,i,i+n.length)===n}})});var Zc=l((_1,Hc)=>{"use strict";var l0=ir();Hc.exports=Array.isArray||function(e){return l0(e)==="Array"}});var zc=l((k1,$c)=>{"use strict";var Yc=Zc(),v0=Zt(),f0=M(),d0=L(),p0=d0("species"),Xc=Array;$c.exports=function(r){var e;return Yc(r)&&(e=r.constructor,v0(e)&&(e===Xc||Yc(e.prototype))?e=void 0:f0(e)&&(e=e[p0],e===null&&(e=void 0))),e===void 0?Xc:e}});var Kc=l((D1,Jc)=>{"use strict";var m0=zc();Jc.exports=function(r,e){return new(m0(r))(e===0?0:e)}});var rl=l((M1,Qc)=>{"use strict";var h0=_(),g0=nr(),y0=ge();Qc.exports=function(r,e,t){h0?g0.f(r,e,y0(0,t)):r[e]=t}});var Wn=l((F1,tl)=>{"use strict";var b0=Br(),w0=xe(),S0=kr(),E0=Oe(),el=Kc(),Gn=rl(),or=function(r){var e=r===1,t=r===2,n=r===3,i=r===4,a=r===6,o=r===7,u=r===5||a;return function(s,c,f){for(var v=S0(s),p=w0(v),d=E0(p),m=b0(c,f),y=0,h=0,g=e?el(s,d):t||o?el(s,0):void 0,w,b;d>y;y++)if((u||y in p)&&(w=p[y],b=m(w,y,v),r))if(e)Gn(g,y,b);else if(b)switch(r){case 3:return!0;case 5:return w;case 6:return y;case 2:Gn(g,h++,w)}else switch(r){case 4:return!1;case 7:Gn(g,h++,w)}return a?-1:n||i?i:g}};tl.exports={forEach:or(0),map:or(1),filter:or(2),some:or(3),every:or(4),find:or(5),findIndex:or(6),filterReject:or(7)}});var Bn=l((V1,nl)=>{"use strict";var I0=T(),q0=L(),C0=ce(),x0=q0("species");nl.exports=function(r){return C0>=51||!I0(function(){var e=[],t=e.constructor={};return t[x0]=function(){return{foo:1}},e[r](Boolean).foo!==1})}});var il=l(()=>{"use strict";var T0=N(),O0=Wn().map,R0=Bn(),P0=R0("map");T0({target:"Array",proto:!0,forced:!P0},{map:function(e){return O0(this,e,arguments.length>1?arguments[1]:void 0)}})});var al=l(()=>{"use strict";var L0=N(),N0=Wn().filter,A0=Bn(),j0=A0("filter");L0({target:"Array",proto:!0,forced:!j0},{filter:function(e){return N0(this,e,arguments.length>1?arguments[1]:void 0)}})});var ul=l(()=>{"use strict";var _0=N(),k0=kr(),ol=Be(),D0=T(),M0=D0(function(){ol(1)});_0({target:"Object",stat:!0,forced:M0},{keys:function(e){return ol(k0(e))}})});var Un=l((Y1,sl)=>{"use strict";sl.exports=`	
\v\f\r \xA0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u202F\u205F\u3000\u2028\u2029\uFEFF`});var vl=l((X1,ll)=>{"use strict";var F0=x(),V0=dr(),G0=$r(),Zn=Un(),cl=F0("".replace),W0=RegExp("^["+Zn+"]+"),B0=RegExp("(^|[^"+Zn+"])["+Zn+"]+$"),Hn=function(r){return function(e){var t=G0(V0(e));return r&1&&(t=cl(t,W0,"")),r&2&&(t=cl(t,B0,"$1")),t}};ll.exports={start:Hn(1),end:Hn(2),trim:Hn(3)}});var yl=l(($1,gl)=>{"use strict";var ml=I(),U0=T(),H0=x(),Z0=$r(),Y0=vl().trim,fl=Un(),zr=ml.parseInt,dl=ml.Symbol,pl=dl&&dl.iterator,hl=/^[+-]?0x/i,X0=H0(hl.exec),$0=zr(fl+"08")!==8||zr(fl+"0x16")!==22||pl&&!U0(function(){zr(Object(pl))});gl.exports=$0?function(e,t){var n=Y0(Z0(e));return zr(n,t>>>0||(X0(hl,n)?16:10))}:zr});var wl=l(()=>{"use strict";var z0=N(),bl=yl();z0({global:!0,forced:parseInt!==bl},{parseInt:bl})});var DS={};Sv(DS,{FlowType:()=>ci,VAULT_FIELD_NAMES:()=>P,clearSessionKey:()=>dv,createCoinmeVault:()=>Pl,getSessionTag:()=>fv,setupCoinmeRiskEngine:()=>pv,submitPaymentMethod:()=>Rl,updateCoinmeRiskEngine:()=>si});var K1=G(Wa()),Q1=G(Ys()),rq=G($s()),eq=G(Qs()),tq=G(oc());var Ue,ty=new Uint8Array(16);function Pn(){if(!Ue&&(Ue=typeof crypto<"u"&&crypto.getRandomValues&&crypto.getRandomValues.bind(crypto)||typeof msCrypto<"u"&&typeof msCrypto.getRandomValues=="function"&&msCrypto.getRandomValues.bind(msCrypto),!Ue))throw new Error("crypto.getRandomValues() not supported. See https://github.com/uuidjs/uuid#getrandomvalues-not-supported");return Ue(ty)}var uc=/^(?:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}|00000000-0000-0000-0000-000000000000)$/i;function ny(r){return typeof r=="string"&&uc.test(r)}var sc=ny;var R=[];for(He=0;He<256;++He)R.push((He+256).toString(16).substr(1));var He;function iy(r){var e=arguments.length>1&&arguments[1]!==void 0?arguments[1]:0,t=(R[r[e+0]]+R[r[e+1]]+R[r[e+2]]+R[r[e+3]]+"-"+R[r[e+4]]+R[r[e+5]]+"-"+R[r[e+6]]+R[r[e+7]]+"-"+R[r[e+8]]+R[r[e+9]]+"-"+R[r[e+10]]+R[r[e+11]]+R[r[e+12]]+R[r[e+13]]+R[r[e+14]]+R[r[e+15]]).toLowerCase();if(!sc(t))throw TypeError("Stringified UUID is invalid");return t}var cc=iy;function ay(r,e,t){r=r||{};var n=r.random||(r.rng||Pn)();if(n[6]=n[6]&15|64,n[8]=n[8]&63|128,e){t=t||0;for(var i=0;i<16;++i)e[t+i]=n[i];return e}return cc(n)}var Ln=ay;var iq=G(_c()),aq=G(Uc()),oq=G(il()),uq=G(al()),sq=G(ul()),cq=G(wl()),Xn="https://js.verygoodvault.com",$n="https://js3.verygoodvault.com",J0="https://vgs-collect-keeper.apps.verygood.systems",ql=Ln(),Yn={vaultId:"",environment:"sandbox",version:"canary"},ze={LOADED_FROM_PACKAGE:"LoadedFromPackage",SCRIPT_LOAD:"ScriptLoad",INSTANCE_UNDEFINED:"InstanceUndefined"},fr={IS_REQUIRED:function(e){return e+" is required."},IS_UNDEFINED:function(e){return e+" is undefined."},IS_INVALID:function(e){return e+" is invalid."},UNABLE_TO_FIND:function(e){return"Unable to find "+e},SCRIPT_WAS_NOT_LOADED:"VGS Collect.js script was not loaded.",CHANGE_VERSION:"Please explicitly set locked VGS Collect.js version before going live. Check out the changelog https://www.verygoodsecurity.com/docs/vgs-collect/js/changelog"},Cl=Yn,K0=function(e){e&&(Cl=Object.assign({},e))},zn=function(){return Cl},Q0={vaultId:function(e){return typeof e=="string"&&/^tnt.{8}$/.test(e)},environment:function(e){return typeof e=="string"&&/^(sandbox|live)((-eu|-ap)-\d{1})?$/.test(e)},version:function(e){return e==="canary"||typeof e=="string"&&/^\d{1,2}\.\d{1,2}(\.\d{1,2}(-beta\.\d{1,2})?)?$/.test(e)&&!e.startsWith("1.")},integrity:function(e){return e?typeof e=="string":!0},crossorigin:function(e){return e?typeof e=="string":!0},logLevel:function(e){return typeof e>"u"?!0:e==="none"}},Sl=function(e){throw new Error(fr.IS_REQUIRED(e))},rb=function(e,t){if(e){var n=Object.keys(e).filter(function(a){return!e[a](t[a])}).map(function(a){return new Error(fr.IS_INVALID(a))});if(n.length){var i=n[0];throw i}}},eb=function(e){rb(Q0,e)},tb=function(e){eb(e),K0(e),Je({type:ze.LOADED_FROM_PACKAGE})},Je=function(e){var t=zn(),n=t.vaultId,i=t.environment,a=t.version,o=t.logLevel;if(!(o==="none"||typeof window>"u"||typeof window.btoa!="function"||typeof fetch!="function")){var u="",s={env:i,tnt:n,userAgent:window.navigator.userAgent,version:a,timestamp:Date.now(),vgsCollectSessionId:ql};try{u=window.btoa(JSON.stringify(Object.assign({},e,s)))}catch{return}fetch(J0+"/vgs",{method:"POST",body:u}).then(function(){return!0}).catch(function(){return!0})}},xl=function(e){var t=document.head||document.body;if(!t)throw new Error(fr.UNABLE_TO_FIND("document.head or document.body"));return t.appendChild(e),e},Ke=function(e,t){var n=document.createElement("link");n.rel=e,n.href=t,xl(n)},El=function(e){var t=e.split("."),n=parseInt(t[0])||0,i=parseInt(t[1])||0,a=parseInt(t[2])||0;return{major:n,minor:i,patch:a}},nb=function(e,t){if(e==="canary")return!0;var n=El(e),i=El(t);return n.major!==i.major?n.major>i.major:n.minor!==i.minor?n.minor>i.minor:n.patch!==i.patch?n.patch>i.patch:!1},Jn=Xn,ib=function(){try{var e=document.querySelectorAll('script[src^="'+Jn+'/vgs-collect/"]');return e.length>0}catch{return!1}},ab=function(){var e=zn(),t=e.vaultId,n=e.environment,i=e.version,a=e.integrity,o=e.crossorigin,u=document.createElement("script");return u.src=Jn+"/vgs-collect/"+i+"/vgs-collect.js?sessionId="+ql+"&tenantId="+t+"&env="+n,a&&(u.integrity=a),typeof o=="string"&&(u.crossOrigin=o),xl(u),u},ob=function r(e){e===void 0&&(e=!0);var t=new Promise(function(n,i){var a=zn(),o=a.version;if(ib()&&window.VGSCollect&&n(window.VGSCollect),!e&&nb(o,"2.3.0")&&(Jn=$n),!window.VGSCollect){var u=ab();u&&(u.onload=function(){window.VGSCollect||(Je({type:ze.INSTANCE_UNDEFINED,status:"OK",mainCDN:e}),i(fr.IS_UNDEFINED("VGS Collect"))),Je({type:ze.SCRIPT_LOAD,status:"OK",mainCDN:e}),n(window.VGSCollect)},u.onerror=function(){Je({type:ze.SCRIPT_LOAD,status:"Failed",mainCDN:e}),e?n(r(!1)):i(fr.SCRIPT_WAS_NOT_LOADED)})}});return t},Il=function(e,t,n){n&&window.VGSCollect&&typeof window.VGSCollect.logLevel=="function"&&window.VGSCollect.logLevel(n),window.VGSCollect.init=function(i){return i===void 0&&(i=function(){}),window.VGSCollect.create(e,t,i)}},ub=function(){Ke("dns-prefetch",Xn),Ke("dns-prefetch",$n)},sb=function(){Ke("preconnect",Xn),Ke("preconnect",$n)};Promise.resolve().then(function(){typeof window<"u"&&!window.VGSCollect&&(ub(),sb())});var Tl=function(e){e===void 0&&(e=Sl("config"));var t=e,n=t.vaultId,i=n===void 0?Sl("vaultId"):n,a=t.environment,o=a===void 0?Yn.environment:a,u=t.version,s=u===void 0?Yn.version:u,c=t.integrity,f=t.crossorigin,v=t.logLevel;return s==="canary"&&console.warn(fr.CHANGE_VERSION),tb({vaultId:i,environment:o,version:s,integrity:c,crossorigin:f,logLevel:v}),new Promise(function(p,d){if(typeof window>"u"){d(fr.IS_UNDEFINED("window"));return}if(window.VGSCollect){Il(i,o,v),p(window.VGSCollect);return}ob().then(function(){Il(i,o,v),p(window.VGSCollect)}).catch(function(m){d(m)})})};var Qe,Q=class extends Error{kind;status;fields;errorResponse;cause;constructor(r,e,t){super(e),this.name="CoinmeVaultError",this.kind=r,t&&"cause"in t&&(this.cause=t.cause),t?.status!==void 0&&(this.status=t.status),t?.fields!==void 0&&(this.fields=t.fields),t?.errorResponse!==void 0&&(this.errorResponse=t.errorResponse)}},cb=r=>{let e={};for(let[t,n]of Object.entries(r))e[t]=(n.errorMessages??[]).map(String);return e},lb=r=>r instanceof Q?r:(e=>{if(typeof e!="object"||e===null||e instanceof Error)return!1;let t=Object.values(e);return t.length>0&&t.every(n=>typeof n=="object"&&n!==null&&Array.isArray(n.errorMessages))})(r)?new Q("validation","Submitted data failed validation.",{cause:r,fields:cb(r)}):new Q("unknown","An unknown vault error occurred.",{cause:r}),P={pan:"pan",cvc:"cvc",expiry:"expiry",address1:"address1",address2:"address2",city:"city",zipcode:"zipcode",exp_month:"exp_month",exp_year:"exp_year"},vb=r=>{let{customerId:e,paymentProcessAssociation:t,paymentProviderId:n,webSessionId:i,billingAddress:a}=r;return{data:o=>{let u=o[P.expiry];return{customerId:e,paymentProcessAssociation:t,providerId:n,webSessionId:i,card:{cardNumber:o[P.pan],cvv:o[P.cvc],month:u?.[P.exp_month],year:u?.[P.exp_year]},billingAddress:{firstName:a.firstName,lastName:a.lastName,addressLine1:o[P.address1],addressLine2:o[P.address2],city:o[P.city],zipCode:o[P.zipcode],state:a.state,country:a.country??"US"}}}}},Rl=(r,e)=>{let{headers:t,timeoutMs:n,...i}=e,{data:a}=vb(i),o={data:a};return t!==void 0&&(o.headers=t),n!==void 0&&(o.timeoutMs=n),r.submit(o)},fb="4.0.1",Jr=(r,e,t,n)=>{let i=r.field(t,n);return e.push(i),i.on("delete",()=>{let a=e.indexOf(i);a!==-1&&e.splice(a,1)}),i},db=(r,e)=>({createCardNumberField:(t,n)=>Jr(r,e,t,{name:P.pan,validations:["required","validCardNumber"],autoComplete:"cc-number",...n,type:"card-number"}),createCvcField:(t,n)=>Jr(r,e,t,{name:P.cvc,validations:["required","validCardSecurityCode"],autoComplete:"cc-csc",...n,type:"card-security-code"}),createExpiryField:(t,n)=>Jr(r,e,t,{name:P.expiry,validations:["required","validCardExpirationDate"],autoComplete:"cc-exp",yearLength:4,serializers:[{name:"separate",options:{monthName:P.exp_month,yearName:P.exp_year}}],...n,type:"card-expiration-date"}),createCardHolderField:(t,n)=>Jr(r,e,t,{name:"cardholder",autoComplete:"cc-name",...n,type:"text"}),createTextField:(t,n)=>Jr(r,e,t,{type:"text",...n})}),Ol={sandbox:{vaultId:"tnt6wanrtvt",vgsEnvironment:"sandbox",ingress:"secure.payments-stage.coinme.com",submitPath:"/services/paymentmethods",submitMethod:"POST"},live:{vaultId:"tntgwkqjuar",vgsEnvironment:"live",ingress:"secure.payments.coinme.com",submitPath:"/services/paymentmethods",submitMethod:"POST"}},pb=r=>{if(typeof r!="object"||r===null)return;let{errorData:e}=r;if(!Array.isArray(e))return;let t=e[0];return typeof t?.message=="string"?t.message:void 0},mb=async(r,e,t,n)=>{let{headers:i,timeoutMs:a,...o}=n??{},u=Math.floor(1e16*Math.random()).toString(),s=(async()=>{try{await Promise.all(t.map(p=>p.promise))}catch(p){throw new Q("network","A secure field failed to load, so the form cannot be submitted. Check the network and that no extension is blocking js.verygoodvault.com.",{cause:p})}return r.submit(e.submitPath,{...o,method:o.method??e.submitMethod,headers:{"X-B3-TraceId":u,"X-B3-SpanId":u,...i}})})(),c,f;try{({status:c,data:f}=await((p,d)=>new Promise((m,y)=>{let h=setTimeout(()=>{y(new Q("network",`Vault request did not complete within ${d}ms.`))},d);p.then(g=>{clearTimeout(h),m(g)},g=>{clearTimeout(h),y(g)})}))(s,a??6e4))}catch(p){throw lb(p)}if(typeof c!="number")throw new Q("network","Network request to the vault failed.",{cause:f});if(c>=400)throw new Q("server",`Vault request failed with status ${c}.`,{cause:{status:c,data:f},status:c});let v=(p=>{if(typeof p!="object"||p===null)return;let{errorResponse:d}=p;return d?{errorResponse:d,message:pb(d)??"The Coinme backend returned an application error."}:void 0})(f);if(v)throw new Q("caas",v.message,{errorResponse:v.errorResponse,status:c});return{ok:!0,status:c,data:f??void 0}},hb=new WeakMap,Pl=async r=>{let{environment:e,config:t,onError:n}=r;try{let i=t?((d,m)=>{if(!m.sandbox||!m.live)throw new Error("[vault-sdk] RuntimeVaultConfig requires both `sandbox` and `live` entries.");if(!m.sandbox.ingress?.trim()||!m.sandbox.path?.trim())throw new Error("[vault-sdk] RuntimeVaultConfig.sandbox requires non-empty ingress and path.");if(!m.live.ingress?.trim()||!m.live.path?.trim())throw new Error("[vault-sdk] RuntimeVaultConfig.live requires non-empty ingress and path.");["sandbox","live"].forEach(w=>{let{vaultId:b}=m[w];if(b!==void 0&&(typeof b!="string"||!b.trim()))throw new Error(`[vault-sdk] RuntimeVaultConfig.${w}.vaultId must be a non-empty string when provided.`)});let y=m[d],h=Ol[d],g=y?.vaultId??h?.vaultId;if(!g)throw new Error(`[vault-sdk] No vault ID found in generated config for environment "${d}". Ensure the build-time env vars are set.`);return{vaultId:g,vgsEnvironment:d,ingress:y.ingress,submitPath:y.path,submitMethod:h?.submitMethod??"POST"}})(e,t):(d=>{let m=Ol[d];if(!m?.vaultId)throw new Error(`[vault-sdk] No vault ID found in generated config for environment "${d}". Ensure the build-time env vars are set.`);return m})(e),a=await((d,m)=>typeof window>"u"?Promise.reject(new Error("[vault-sdk] VGS Collect.js can only load in a browser. Create the vault from client-side code (e.g. after mount / inside useEffect).")):(Qe||(Qe=Promise.resolve(Tl({vaultId:d,environment:m,version:fb})).then(y=>y,y=>{throw Qe=void 0,new Q("network","[vault-sdk] Failed to load VGS Collect.js from the VGS CDN. Check the network and that your CSP allows js.verygoodvault.com and js3.verygoodvault.com.",{cause:y})})),Qe))(i.vaultId,i.vgsEnvironment),o={},u=new Set,s=a.create(i.vaultId,i.vgsEnvironment,d=>{o=d,u.forEach(m=>m())}),c=(d=>{let m=d.trim();if(m)try{return new URL(m.includes("://")?m:`https://${m}`).host}catch{return m.replace(/^https?:\/\//i,"").replace(/\/.*$/,"")}})(i.ingress);c&&s.useCname(c);let f=[],v=(d=>{let m,y;return()=>{let h=d();if(h!==m||!y){let g=Object.keys(h);m=h,y={isValid:g.length>0&&g.every(w=>h[w]?.isValid===!0),fields:h}}return y}})(()=>o),p={form:s,environment:e,...db(s,f),getFormState:v,subscribe:d=>(u.add(d),()=>{u.delete(d)}),submit:d=>mb(s,i,f,d),dispose:()=>{s.unmount()}};return hb.set(p,{config:i,trackedFields:f}),p}catch(i){throw n?.(i),i}};var ei=function(){return ei=Object.assign||function(e){for(var t,n=1,i=arguments.length;n<i;n++){t=arguments[n];for(var a in t)Object.prototype.hasOwnProperty.call(t,a)&&(e[a]=t[a])}return e},ei.apply(this,arguments)};function z(r,e,t,n){function i(a){return a instanceof t?a:new t(function(o){o(a)})}return new(t||(t=Promise))(function(a,o){function u(f){try{c(n.next(f))}catch(v){o(v)}}function s(f){try{c(n.throw(f))}catch(v){o(v)}}function c(f){f.done?a(f.value):i(f.value).then(u,s)}c((n=n.apply(r,e||[])).next())})}function J(r,e){var t={label:0,sent:function(){if(a[0]&1)throw a[1];return a[1]},trys:[],ops:[]},n,i,a,o=Object.create((typeof Iterator=="function"?Iterator:Object).prototype);return o.next=u(0),o.throw=u(1),o.return=u(2),typeof Symbol=="function"&&(o[Symbol.iterator]=function(){return this}),o;function u(c){return function(f){return s([c,f])}}function s(c){if(n)throw new TypeError("Generator is already executing.");for(;o&&(o=0,c[0]&&(t=0)),t;)try{if(n=1,i&&(a=c[0]&2?i.return:c[0]?i.throw||((a=i.return)&&a.call(i),0):i.next)&&!(a=a.call(i,c[1])).done)return a;switch(i=0,a&&(c=[c[0]&2,a.value]),c[0]){case 0:case 1:a=c;break;case 4:return t.label++,{value:c[1],done:!1};case 5:t.label++,i=c[1],c=[0];continue;case 7:c=t.ops.pop(),t.trys.pop();continue;default:if(a=t.trys,!(a=a.length>0&&a[a.length-1])&&(c[0]===6||c[0]===2)){t=0;continue}if(c[0]===3&&(!a||c[1]>a[0]&&c[1]<a[3])){t.label=c[1];break}if(c[0]===6&&t.label<a[1]){t.label=a[1],a=c;break}if(a&&t.label<a[2]){t.label=a[2],t.ops.push(c);break}a[2]&&t.ops.pop(),t.trys.pop();continue}c=e.call(r,t)}catch(f){c=[6,f],i=0}finally{n=a=0}if(c[0]&5)throw c[1];return{value:c[0]?c[1]:void 0,done:!0}}}function Hl(r,e,t){if(t||arguments.length===2)for(var n=0,i=e.length,a;n<i;n++)(a||!(n in e))&&(a||(a=Array.prototype.slice.call(e,0,n)),a[n]=e[n]);return r.concat(a||Array.prototype.slice.call(e))}var Zl="4.5.1";function nt(r,e){return new Promise(function(t){return setTimeout(t,r,e)})}function gb(){return new Promise(function(r){var e=new MessageChannel;e.port1.onmessage=function(){return r()},e.port2.postMessage(null)})}function yb(r,e){e===void 0&&(e=1/0);var t=window.requestIdleCallback;return t?new Promise(function(n){return t.call(window,function(){return n()},{timeout:e})}):nt(Math.min(r,e))}function Yl(r){return!!r&&typeof r.then=="function"}function Ll(r,e){try{var t=r();Yl(t)?t.then(function(n){return e(!0,n)},function(n){return e(!1,n)}):e(!0,t)}catch(n){e(!1,n)}}function Nl(r,e,t){return t===void 0&&(t=16),z(this,void 0,void 0,function(){var n,i,a,o;return J(this,function(u){switch(u.label){case 0:n=Array(r.length),i=Date.now(),a=0,u.label=1;case 1:return a<r.length?(n[a]=e(r[a],a),o=Date.now(),o>=i+t?(i=o,[4,gb()]):[3,3]):[3,4];case 2:u.sent(),u.label=3;case 3:return++a,[3,1];case 4:return[2,n]}})})}function Kr(r){return r.then(void 0,function(){}),r}function bb(r,e){for(var t=0,n=r.length;t<n;++t)if(r[t]===e)return!0;return!1}function wb(r,e){return!bb(r,e)}function ii(r){return parseInt(r)}function H(r){return parseFloat(r)}function rr(r,e){return typeof r=="number"&&isNaN(r)?e:r}function j(r){return r.reduce(function(e,t){return e+(t?1:0)},0)}function Xl(r,e){if(e===void 0&&(e=1),Math.abs(e)>=1)return Math.round(r/e)*e;var t=1/e;return Math.round(r*t)/t}function Sb(r){for(var e,t,n="Unexpected syntax '".concat(r,"'"),i=/^\s*([a-z-]*)(.*)$/i.exec(r),a=i[1]||void 0,o={},u=/([.:#][\w-]+|\[.+?\])/gi,s=function(p,d){o[p]=o[p]||[],o[p].push(d)};;){var c=u.exec(i[2]);if(!c)break;var f=c[0];switch(f[0]){case".":s("class",f.slice(1));break;case"#":s("id",f.slice(1));break;case"[":{var v=/^\[([\w-]+)([~|^$*]?=("(.*?)"|([\w-]+)))?(\s+[is])?\]$/.exec(f);if(v)s(v[1],(t=(e=v[4])!==null&&e!==void 0?e:v[5])!==null&&t!==void 0?t:"");else throw new Error(n);break}default:throw new Error(n)}}return[a,o]}function Eb(r){for(var e=new Uint8Array(r.length),t=0;t<r.length;t++){var n=r.charCodeAt(t);if(n>127)return new TextEncoder().encode(r);e[t]=n}return e}function ur(r,e){var t=r[0]>>>16,n=r[0]&65535,i=r[1]>>>16,a=r[1]&65535,o=e[0]>>>16,u=e[0]&65535,s=e[1]>>>16,c=e[1]&65535,f=0,v=0,p=0,d=0;d+=a+c,p+=d>>>16,d&=65535,p+=i+s,v+=p>>>16,p&=65535,v+=n+u,f+=v>>>16,v&=65535,f+=t+o,f&=65535,r[0]=f<<16|v,r[1]=p<<16|d}function V(r,e){var t=r[0]>>>16,n=r[0]&65535,i=r[1]>>>16,a=r[1]&65535,o=e[0]>>>16,u=e[0]&65535,s=e[1]>>>16,c=e[1]&65535,f=0,v=0,p=0,d=0;d+=a*c,p+=d>>>16,d&=65535,p+=i*c,v+=p>>>16,p&=65535,p+=a*s,v+=p>>>16,p&=65535,v+=n*c,f+=v>>>16,v&=65535,v+=i*s,f+=v>>>16,v&=65535,v+=a*u,f+=v>>>16,v&=65535,f+=t*c+n*s+i*u+a*o,f&=65535,r[0]=f<<16|v,r[1]=p<<16|d}function Or(r,e){var t=r[0];e%=64,e===32?(r[0]=r[1],r[1]=t):e<32?(r[0]=t<<e|r[1]>>>32-e,r[1]=r[1]<<e|t>>>32-e):(e-=32,r[0]=r[1]<<e|t>>>32-e,r[1]=t<<e|r[1]>>>32-e)}function D(r,e){e%=64,e!==0&&(e<32?(r[0]=r[1]>>>32-e,r[1]=r[1]<<e):(r[0]=r[1]<<e-32,r[1]=0))}function q(r,e){r[0]^=e[0],r[1]^=e[1]}var Ib=[4283543511,3981806797],qb=[3301882366,444984403];function Al(r){var e=[0,r[0]>>>1];q(r,e),V(r,Ib),e[1]=r[0]>>>1,q(r,e),V(r,qb),e[1]=r[0]>>>1,q(r,e)}var rt=[2277735313,289559509],et=[1291169091,658871167],jl=[0,5],Cb=[0,1390208809],xb=[0,944331445];function Tb(r,e){var t=Eb(r);e=e||0;var n=[0,t.length],i=n[1]%16,a=n[1]-i,o=[0,e],u=[0,e],s=[0,0],c=[0,0],f;for(f=0;f<a;f=f+16)s[0]=t[f+4]|t[f+5]<<8|t[f+6]<<16|t[f+7]<<24,s[1]=t[f]|t[f+1]<<8|t[f+2]<<16|t[f+3]<<24,c[0]=t[f+12]|t[f+13]<<8|t[f+14]<<16|t[f+15]<<24,c[1]=t[f+8]|t[f+9]<<8|t[f+10]<<16|t[f+11]<<24,V(s,rt),Or(s,31),V(s,et),q(o,s),Or(o,27),ur(o,u),V(o,jl),ur(o,Cb),V(c,et),Or(c,33),V(c,rt),q(u,c),Or(u,31),ur(u,o),V(u,jl),ur(u,xb);s[0]=0,s[1]=0,c[0]=0,c[1]=0;var v=[0,0];switch(i){case 15:v[1]=t[f+14],D(v,48),q(c,v);case 14:v[1]=t[f+13],D(v,40),q(c,v);case 13:v[1]=t[f+12],D(v,32),q(c,v);case 12:v[1]=t[f+11],D(v,24),q(c,v);case 11:v[1]=t[f+10],D(v,16),q(c,v);case 10:v[1]=t[f+9],D(v,8),q(c,v);case 9:v[1]=t[f+8],q(c,v),V(c,et),Or(c,33),V(c,rt),q(u,c);case 8:v[1]=t[f+7],D(v,56),q(s,v);case 7:v[1]=t[f+6],D(v,48),q(s,v);case 6:v[1]=t[f+5],D(v,40),q(s,v);case 5:v[1]=t[f+4],D(v,32),q(s,v);case 4:v[1]=t[f+3],D(v,24),q(s,v);case 3:v[1]=t[f+2],D(v,16),q(s,v);case 2:v[1]=t[f+1],D(v,8),q(s,v);case 1:v[1]=t[f],q(s,v),V(s,rt),Or(s,31),V(s,et),q(o,s)}return q(o,n),q(u,n),ur(o,u),ur(u,o),Al(o),Al(u),ur(o,u),ur(u,o),("00000000"+(o[0]>>>0).toString(16)).slice(-8)+("00000000"+(o[1]>>>0).toString(16)).slice(-8)+("00000000"+(u[0]>>>0).toString(16)).slice(-8)+("00000000"+(u[1]>>>0).toString(16)).slice(-8)}function Ob(r){var e;return ei({name:r.name,message:r.message,stack:(e=r.stack)===null||e===void 0?void 0:e.split(`
`)},r)}function Rb(r){return/^function\s.*?\{\s*\[native code]\s*}$/.test(String(r))}function Pb(r){return typeof r!="function"}function Lb(r,e){var t=Kr(new Promise(function(n){var i=Date.now();Ll(r.bind(null,e),function(){for(var a=[],o=0;o<arguments.length;o++)a[o]=arguments[o];var u=Date.now()-i;if(!a[0])return n(function(){return{error:a[1],duration:u}});var s=a[1];if(Pb(s))return n(function(){return{value:s,duration:u}});n(function(){return new Promise(function(c){var f=Date.now();Ll(s,function(){for(var v=[],p=0;p<arguments.length;p++)v[p]=arguments[p];var d=u+Date.now()-f;if(!v[0])return c({error:v[1],duration:d});c({value:v[1],duration:d})})})})})}));return function(){return t.then(function(i){return i()})}}function Nb(r,e,t,n){var i=Object.keys(r).filter(function(o){return wb(t,o)}),a=Kr(Nl(i,function(o){return Lb(r[o],e)},n));return function(){return z(this,void 0,void 0,function(){var u,s,c,f,v;return J(this,function(p){switch(p.label){case 0:return[4,a];case 1:return u=p.sent(),[4,Nl(u,function(d){return Kr(d())},n)];case 2:return s=p.sent(),[4,Promise.all(s)];case 3:for(c=p.sent(),f={},v=0;v<i.length;++v)f[i[v]]=c[v];return[2,f]}})})}}function $l(){var r=window,e=navigator;return j(["MSCSSMatrix"in r,"msSetImmediate"in r,"msIndexedDB"in r,"msMaxTouchPoints"in e,"msPointerEnabled"in e])>=4}function Ab(){var r=window,e=navigator;return j(["msWriteProfilerMark"in r,"MSStream"in r,"msLaunchUri"in e,"msSaveBlob"in e])>=3&&!$l()}function Qr(){var r=window,e=navigator;return j(["webkitPersistentStorage"in e,"webkitTemporaryStorage"in e,e.vendor.indexOf("Google")===0,"webkitResolveLocalFileSystemURL"in r,"BatteryManager"in r,"webkitMediaStream"in r,"webkitSpeechGrammar"in r])>=5}function Z(){var r=window,e=navigator;return j(["ApplePayError"in r,"CSSPrimitiveValue"in r,"Counter"in r,e.vendor.indexOf("Apple")===0,"RGBColor"in r,"WebKitMediaKeys"in r])>=4}function ai(){var r=window,e=r.HTMLElement,t=r.Document;return j(["safari"in r,!("ongestureend"in r),!("TouchEvent"in r),!("orientation"in r),e&&!("autocapitalize"in e.prototype),t&&"pointerLockElement"in t.prototype])>=4}function re(){var r=window;return Rb(r.print)&&String(r.browser)==="[object WebPageNamespace]"}function zl(){var r,e,t=window;return j(["buildID"in navigator,"MozAppearance"in((e=(r=document.documentElement)===null||r===void 0?void 0:r.style)!==null&&e!==void 0?e:{}),"onmozfullscreenchange"in t,"mozInnerScreenX"in t,"CSSMozDocumentRule"in t,"CanvasCaptureMediaStream"in t])>=4}function jb(){var r=window;return j([!("MediaSettingsRange"in r),"RTCEncodedAudioFrame"in r,""+r.Intl=="[object Intl]",""+r.Reflect=="[object Reflect]"])>=3}function _b(){var r=window,e=r.URLPattern;return j(["union"in Set.prototype,"Iterator"in r,e&&"hasRegExpGroups"in e.prototype,"RGB8"in WebGLRenderingContext.prototype])>=3}function kb(){var r=window;return j(["DOMRectList"in r,"RTCPeerConnectionIceEvent"in r,"SVGGeometryElement"in r,"ontransitioncancel"in r])>=3}function ee(){var r=window,e=navigator,t=r.CSS,n=r.HTMLButtonElement;return j([!("getStorageUpdates"in e),n&&"popover"in n.prototype,"CSSCounterStyleRule"in r,t.supports("font-size-adjust: ex-height 0.5"),t.supports("text-transform: full-width")])>=4}function Db(){if(navigator.platform==="iPad")return!0;var r=screen,e=r.width/r.height;return j(["MediaSource"in window,!!Element.prototype.webkitRequestFullscreen,e>.65&&e<1.53])>=2}function Mb(){var r=document;return r.fullscreenElement||r.msFullscreenElement||r.mozFullScreenElement||r.webkitFullscreenElement||null}function Fb(){var r=document;return(r.exitFullscreen||r.msExitFullscreen||r.mozCancelFullScreen||r.webkitExitFullscreen).call(r)}function oi(){var r=Qr(),e=zl(),t=window,n=navigator,i="connection";return r?j([!("SharedWorker"in t),n[i]&&"ontypechange"in n[i],!("sinkId"in new Audio)])>=2:e?j(["onorientationchange"in t,"orientation"in t,/android/i.test(n.appVersion)])>=2:!1}function Vb(){var r=navigator,e=window,t=Audio.prototype,n=e.visualViewport;return j(["srLatency"in t,"srChannelCount"in t,"devicePosture"in r,n&&"segments"in n,"getTextInformation"in Image.prototype])>=3}function Gb(){return Ub()?-4:Wb()}function Wb(){var r=window,e=r.OfflineAudioContext||r.webkitOfflineAudioContext;if(!e)return-2;if(Bb())return-1;var t=4500,n=5e3,i=new e(1,n,44100),a=i.createOscillator();a.type="triangle",a.frequency.value=1e4;var o=i.createDynamicsCompressor();o.threshold.value=-50,o.knee.value=40,o.ratio.value=12,o.attack.value=0,o.release.value=.25,a.connect(o),o.connect(i.destination),a.start(0);var u=Hb(i),s=u[0],c=u[1],f=Kr(s.then(function(v){return Zb(v.getChannelData(0).subarray(t))},function(v){if(v.name==="timeout"||v.name==="suspended")return-3;throw v}));return function(){return c(),f}}function Bb(){return Z()&&!ai()&&!kb()}function Ub(){return Z()&&ee()&&re()||Qr()&&Vb()&&_b()}function Hb(r){var e=3,t=500,n=500,i=5e3,a=function(){},o=new Promise(function(u,s){var c=!1,f=0,v=0;r.oncomplete=function(m){return u(m.renderedBuffer)};var p=function(){setTimeout(function(){return s(_l("timeout"))},Math.min(n,v+i-Date.now()))},d=function(){try{var m=r.startRendering();switch(Yl(m)&&Kr(m),r.state){case"running":v=Date.now(),c&&p();break;case"suspended":document.hidden||f++,c&&f>=e?s(_l("suspended")):setTimeout(d,t);break}}catch(y){s(y)}};d(),a=function(){c||(c=!0,v>0&&p())}});return[o,a]}function Zb(r){for(var e=0,t=0;t<r.length;++t)e+=Math.abs(r[t]);return e}function _l(r){var e=new Error(r);return e.name=r,e}function Jl(r,e,t){var n,i,a;return t===void 0&&(t=50),z(this,void 0,void 0,function(){var o,u;return J(this,function(s){switch(s.label){case 0:o=document,s.label=1;case 1:return o.body?[3,3]:[4,nt(t)];case 2:return s.sent(),[3,1];case 3:u=o.createElement("iframe"),s.label=4;case 4:return s.trys.push([4,,10,11]),[4,new Promise(function(c,f){var v=!1,p=function(){v=!0,c()},d=function(h){v=!0,f(h)};u.onload=p,u.onerror=d;var m=u.style;m.setProperty("display","block","important"),m.position="absolute",m.top="0",m.left="0",m.visibility="hidden",e&&"srcdoc"in u?u.srcdoc=e:u.src="about:blank",o.body.appendChild(u);var y=function(){var h,g;v||(((g=(h=u.contentWindow)===null||h===void 0?void 0:h.document)===null||g===void 0?void 0:g.readyState)==="complete"?p():setTimeout(y,10))};y()})];case 5:s.sent(),s.label=6;case 6:return!((i=(n=u.contentWindow)===null||n===void 0?void 0:n.document)===null||i===void 0)&&i.body?[3,8]:[4,nt(t)];case 7:return s.sent(),[3,6];case 8:return[4,r(u,u.contentWindow)];case 9:return[2,s.sent()];case 10:return(a=u.parentNode)===null||a===void 0||a.removeChild(u),[7];case 11:return[2]}})})}function Yb(r){for(var e=Sb(r),t=e[0],n=e[1],i=document.createElement(t??"div"),a=0,o=Object.keys(n);a<o.length;a++){var u=o[a],s=n[u].join(" ");u==="style"?Xb(i.style,s):i.setAttribute(u,s)}return i}function Xb(r,e){for(var t=0,n=e.split(";");t<n.length;t++){var i=n[t],a=/^\s*([\w-]+)\s*:\s*(.+?)(\s*!([\w-]+))?\s*$/.exec(i);if(a){var o=a[1],u=a[2],s=a[4];r.setProperty(o,u,s||"")}}}function $b(){for(var r=window;;){var e=r.parent;if(!e||e===r)return!1;try{if(e.location.origin!==r.location.origin)return!0}catch(t){if(t instanceof Error&&t.name==="SecurityError")return!0;throw t}r=e}}var zb="mmMwWLliI0O&1",Jb="48px",Rr=["monospace","sans-serif","serif"],kl=["sans-serif-thin","ARNO PRO","Agency FB","Arabic Typesetting","Arial Unicode MS","AvantGarde Bk BT","BankGothic Md BT","Batang","Bitstream Vera Sans Mono","Calibri","Century","Century Gothic","Clarendon","EUROSTILE","Franklin Gothic","Futura Bk BT","Futura Md BT","GOTHAM","Gill Sans","HELV","Haettenschweiler","Helvetica Neue","Humanst521 BT","Leelawadee","Letter Gothic","Levenim MT","Lucida Bright","Lucida Sans","Menlo","MS Mincho","MS Outlook","MS Reference Specialty","MS UI Gothic","MT Extra","MYRIAD PRO","Marlett","Meiryo UI","Microsoft Uighur","Minion Pro","Monotype Corsiva","PMingLiU","Pristina","SCRIPTINA","Segoe UI Light","Serifa","SimHei","Small Fonts","Staccato222 BT","TRAJAN PRO","Univers CE 55 Medium","Vrinda","ZWAdobeF"];function Kb(){var r=this;return Jl(function(e,t){var n=t.document;return z(r,void 0,void 0,function(){var i,a,o,u,s,c,f,v,p,d,m,y;return J(this,function(h){for(i=n.body,i.style.fontSize=Jb,a=n.createElement("div"),a.style.setProperty("visibility","hidden","important"),o={},u={},s=function(g){var w=n.createElement("span"),b=w.style;return b.position="absolute",b.top="0",b.left="0",b.fontFamily=g,w.textContent=zb,a.appendChild(w),w},c=function(g,w){return s("'".concat(g,"',").concat(w))},f=function(){return Rr.map(s)},v=function(){for(var g={},w=function(X){g[X]=Rr.map(function(K){return c(X,K)})},b=0,C=kl;b<C.length;b++){var Y=C[b];w(Y)}return g},p=function(g){return Rr.some(function(w,b){return g[b].offsetWidth!==o[w]||g[b].offsetHeight!==u[w]})},d=f(),m=v(),i.appendChild(a),y=0;y<Rr.length;y++)o[Rr[y]]=d[y].offsetWidth,u[Rr[y]]=d[y].offsetHeight;return[2,kl.filter(function(g){return p(m[g])})]})})})}function Qb(){var r=navigator.plugins;if(r){for(var e=[],t=0;t<r.length;++t){var n=r[t];if(n){for(var i=[],a=0;a<n.length;++a){var o=n[a];i.push({type:o.type,suffixes:o.suffixes})}e.push({name:n.name,description:n.description,mimeTypes:i})}}return e}}function rw(){return ew(sw())}function ew(r){var e,t=!1,n,i,a=tw(),o=a[0],u=a[1];return nw(o,u)?(t=iw(u),r?n=i="skipped":(e=aw(o,u),n=e[0],i=e[1])):n=i="unsupported",{winding:t,geometry:n,text:i}}function tw(){var r=document.createElement("canvas");return r.width=1,r.height=1,[r,r.getContext("2d")]}function nw(r,e){return!!(e&&r.toDataURL)}function iw(r){return r.rect(0,0,10,10),r.rect(2,2,6,6),!r.isPointInPath(5,5,"evenodd")}function aw(r,e){ow(r,e);var t=Kn(r),n=Kn(r);if(t!==n)return["unstable","unstable"];uw(r,e);var i=Kn(r);return[i,t]}function ow(r,e){r.width=240,r.height=60,e.textBaseline="alphabetic",e.fillStyle="#f60",e.fillRect(100,1,62,20),e.fillStyle="#069",e.font='11pt "Times New Roman"';var t="Cwm fjordbank gly ".concat("\u{1F603}");e.fillText(t,2,15),e.fillStyle="rgba(102, 204, 0, 0.2)",e.font="18pt Arial",e.fillText(t,4,45)}function uw(r,e){r.width=122,r.height=110,e.globalCompositeOperation="multiply";for(var t=0,n=[["#f2f",40,40],["#2ff",80,40],["#ff2",60,80]];t<n.length;t++){var i=n[t],a=i[0],o=i[1],u=i[2];e.fillStyle=a,e.beginPath(),e.arc(o,u,40,0,Math.PI*2,!0),e.closePath(),e.fill()}e.fillStyle="#f9c",e.arc(60,60,60,0,Math.PI*2,!0),e.arc(60,60,20,0,Math.PI*2,!0),e.fill("evenodd")}function Kn(r){return r.toDataURL()}function sw(){return Z()&&ee()&&re()}function cw(){var r=navigator,e=0,t;r.maxTouchPoints!==void 0?e=ii(r.maxTouchPoints):r.msMaxTouchPoints!==void 0&&(e=r.msMaxTouchPoints);try{document.createEvent("TouchEvent"),t=!0}catch{t=!1}var n="ontouchstart"in window;return{maxTouchPoints:e,touchEvent:t,touchStart:n}}function lw(){return navigator.oscpu}function vw(){var r=navigator,e=[],t=r.language||r.userLanguage||r.browserLanguage||r.systemLanguage;if(t!==void 0&&e.push([t]),Array.isArray(r.languages))Qr()&&jb()||e.push(r.languages);else if(typeof r.languages=="string"){var n=r.languages;n&&e.push(n.split(","))}return e}function fw(){return window.screen.colorDepth}function dw(){return rr(H(navigator.deviceMemory),void 0)}function pw(){if(!(Z()&&ee()&&re()))return mw()}function mw(){var r=screen,e=function(n){return rr(ii(n),null)},t=[e(r.width),e(r.height)];return t.sort().reverse(),t}var hw=2500,gw=10,tt,Qn;function yw(){if(Qn===void 0){var r=function(){var e=ti();ni(e)?Qn=setTimeout(r,hw):(tt=e,Qn=void 0)};r()}}function bw(){var r=this;return yw(),function(){return z(r,void 0,void 0,function(){var e;return J(this,function(t){switch(t.label){case 0:return e=ti(),ni(e)?tt?[2,Hl([],tt,!0)]:Mb()?[4,Fb()]:[3,2]:[3,2];case 1:t.sent(),e=ti(),t.label=2;case 2:return ni(e)||(tt=e),[2,e]}})})}}function ww(){var r=this;if(Z()&&ee()&&re())return function(){return Promise.resolve(void 0)};var e=bw();return function(){return z(r,void 0,void 0,function(){var t,n;return J(this,function(i){switch(i.label){case 0:return[4,e()];case 1:return t=i.sent(),n=function(a){return a===null?null:Xl(a,gw)},[2,[n(t[0]),n(t[1]),n(t[2]),n(t[3])]]}})})}}function ti(){var r=screen;return[rr(H(r.availTop),null),rr(H(r.width)-H(r.availWidth)-rr(H(r.availLeft),0),null),rr(H(r.height)-H(r.availHeight)-rr(H(r.availTop),0),null),rr(H(r.availLeft),null)]}function ni(r){for(var e=0;e<4;++e)if(r[e])return!1;return!0}function Sw(){return rr(ii(navigator.hardwareConcurrency),void 0)}function Ew(){var r,e=(r=window.Intl)===null||r===void 0?void 0:r.DateTimeFormat;if(e){var t=new e().resolvedOptions().timeZone;if(t)return t}var n=-Iw();return"UTC".concat(n>=0?"+":"").concat(n)}function Iw(){var r=new Date().getFullYear();return Math.max(H(new Date(r,0,1).getTimezoneOffset()),H(new Date(r,6,1).getTimezoneOffset()))}function qw(){try{return!!window.sessionStorage}catch{return!0}}function Cw(){try{return!!window.localStorage}catch{return!0}}function xw(){if(!($l()||Ab()))try{return!!window.indexedDB}catch{return!0}}function Tw(){return!!window.openDatabase}function Ow(){return navigator.cpuClass}function Rw(){var r=navigator.platform;return r==="MacIntel"&&Z()&&!ai()?Db()?"iPad":"iPhone":r}function Pw(){return navigator.vendor||""}function Lw(){for(var r=[],e=0,t=["chrome","safari","__crWeb","__gCrWeb","yandex","__yb","__ybro","__firefox__","__edgeTrackingPreventionStatistics","webkit","oprt","samsungAr","ucweb","UCShellJava","puffinDevice"];e<t.length;e++){var n=t[e],i=window[n];i&&typeof i=="object"&&r.push(n)}return r.sort()}function Nw(){var r=document;try{r.cookie="cookietest=1; SameSite=Strict;";var e=r.cookie.indexOf("cookietest=")!==-1;return r.cookie="cookietest=1; SameSite=Strict; expires=Thu, 01-Jan-1970 00:00:01 GMT",e}catch{return!1}}function Aw(){var r=atob;return{abpIndo:["#Iklan-Melayang","#Kolom-Iklan-728","#SidebarIklan-wrapper",'[title="ALIENBOLA" i]',r("I0JveC1CYW5uZXItYWRz")],abpvn:[".quangcao","#mobileCatfish",r("LmNsb3NlLWFkcw=="),'[id^="bn_bottom_fixed_"]',"#pmadv"],adBlockFinland:[".mainostila",r("LnNwb25zb3JpdA=="),".ylamainos",r("YVtocmVmKj0iL2NsaWNrdGhyZ2guYXNwPyJd"),r("YVtocmVmXj0iaHR0cHM6Ly9hcHAucmVhZHBlYWsuY29tL2FkcyJd")],adBlockPersian:["#navbar_notice_50",".kadr",'TABLE[width="140px"]',"#divAgahi",r("YVtocmVmXj0iaHR0cDovL2cxLnYuZndtcm0ubmV0L2FkLyJd")],adBlockWarningRemoval:["#adblock-honeypot",".adblocker-root",".wp_adblock_detect",r("LmhlYWRlci1ibG9ja2VkLWFk"),r("I2FkX2Jsb2NrZXI=")],adGuardAnnoyances:[".hs-sosyal","#cookieconsentdiv",'div[class^="app_gdpr"]',".as-oil",'[data-cypress="soft-push-notification-modal"]'],adGuardBase:[".BetterJsPopOverlay",r("I2FkXzMwMFgyNTA="),r("I2Jhbm5lcmZsb2F0MjI="),r("I2NhbXBhaWduLWJhbm5lcg=="),r("I0FkLUNvbnRlbnQ=")],adGuardChinese:[r("LlppX2FkX2FfSA=="),r("YVtocmVmKj0iLmh0aGJldDM0LmNvbSJd"),"#widget-quan",r("YVtocmVmKj0iLzg0OTkyMDIwLnh5eiJd"),r("YVtocmVmKj0iLjE5NTZobC5jb20vIl0=")],adGuardFrench:["#pavePub",r("LmFkLWRlc2t0b3AtcmVjdGFuZ2xl"),".mobile_adhesion",".widgetadv",r("LmFkc19iYW4=")],adGuardGerman:['aside[data-portal-id="leaderboard"]'],adGuardJapanese:["#kauli_yad_1",r("YVtocmVmXj0iaHR0cDovL2FkMi50cmFmZmljZ2F0ZS5uZXQvIl0="),r("Ll9wb3BJbl9pbmZpbml0ZV9hZA=="),r("LmFkZ29vZ2xl"),r("Ll9faXNib29zdFJldHVybkFk")],adGuardMobile:[r("YW1wLWF1dG8tYWRz"),r("LmFtcF9hZA=="),'amp-embed[type="24smi"]',"#mgid_iframe1",r("I2FkX2ludmlld19hcmVh")],adGuardRussian:[r("YVtocmVmXj0iaHR0cHM6Ly9hZC5sZXRtZWFkcy5jb20vIl0="),r("LnJlY2xhbWE="),'div[id^="smi2adblock"]',r("ZGl2W2lkXj0iQWRGb3hfYmFubmVyXyJd"),"#psyduckpockeball"],adGuardSocial:[r("YVtocmVmXj0iLy93d3cuc3R1bWJsZXVwb24uY29tL3N1Ym1pdD91cmw9Il0="),r("YVtocmVmXj0iLy90ZWxlZ3JhbS5tZS9zaGFyZS91cmw/Il0="),".etsy-tweet","#inlineShare",".popup-social"],adGuardSpanishPortuguese:["#barraPublicidade","#Publicidade","#publiEspecial","#queTooltip",".cnt-publi"],adGuardTrackingProtection:["#qoo-counter",r("YVtocmVmXj0iaHR0cDovL2NsaWNrLmhvdGxvZy5ydS8iXQ=="),r("YVtocmVmXj0iaHR0cDovL2hpdGNvdW50ZXIucnUvdG9wL3N0YXQucGhwIl0="),r("YVtocmVmXj0iaHR0cDovL3RvcC5tYWlsLnJ1L2p1bXAiXQ=="),"#top100counter"],adGuardTurkish:["#backkapat",r("I3Jla2xhbWk="),r("YVtocmVmXj0iaHR0cDovL2Fkc2Vydi5vbnRlay5jb20udHIvIl0="),r("YVtocmVmXj0iaHR0cDovL2l6bGVuemkuY29tL2NhbXBhaWduLyJd"),r("YVtocmVmXj0iaHR0cDovL3d3dy5pbnN0YWxsYWRzLm5ldC8iXQ==")],bulgarian:[r("dGQjZnJlZW5ldF90YWJsZV9hZHM="),"#ea_intext_div",".lapni-pop-over","#xenium_hot_offers"],easyList:[".yb-floorad",r("LndpZGdldF9wb19hZHNfd2lkZ2V0"),r("LnRyYWZmaWNqdW5reS1hZA=="),".textad_headline",r("LnNwb25zb3JlZC10ZXh0LWxpbmtz")],easyListChina:[r("LmFwcGd1aWRlLXdyYXBbb25jbGljayo9ImJjZWJvcy5jb20iXQ=="),r("LmZyb250cGFnZUFkdk0="),"#taotaole","#aafoot.top_box",".cfa_popup"],easyListCookie:[".ezmob-footer",".cc-CookieWarning","[data-cookie-number]",r("LmF3LWNvb2tpZS1iYW5uZXI="),".sygnal24-gdpr-modal-wrap"],easyListCzechSlovak:["#onlajny-stickers",r("I3Jla2xhbW5pLWJveA=="),r("LnJla2xhbWEtbWVnYWJvYXJk"),".sklik",r("W2lkXj0ic2tsaWtSZWtsYW1hIl0=")],easyListDutch:[r("I2FkdmVydGVudGll"),r("I3ZpcEFkbWFya3RCYW5uZXJCbG9jaw=="),".adstekst",r("YVtocmVmXj0iaHR0cHM6Ly94bHR1YmUubmwvY2xpY2svIl0="),"#semilo-lrectangle"],easyListGermany:["#SSpotIMPopSlider",r("LnNwb25zb3JsaW5rZ3J1ZW4="),r("I3dlcmJ1bmdza3k="),r("I3Jla2xhbWUtcmVjaHRzLW1pdHRl"),r("YVtocmVmXj0iaHR0cHM6Ly9iZDc0Mi5jb20vIl0=")],easyListItaly:[r("LmJveF9hZHZfYW5udW5jaQ=="),".sb-box-pubbliredazionale",r("YVtocmVmXj0iaHR0cDovL2FmZmlsaWF6aW9uaWFkcy5zbmFpLml0LyJd"),r("YVtocmVmXj0iaHR0cHM6Ly9hZHNlcnZlci5odG1sLml0LyJd"),r("YVtocmVmXj0iaHR0cHM6Ly9hZmZpbGlhemlvbmlhZHMuc25haS5pdC8iXQ==")],easyListLithuania:[r("LnJla2xhbW9zX3RhcnBhcw=="),r("LnJla2xhbW9zX251b3JvZG9z"),r("aW1nW2FsdD0iUmVrbGFtaW5pcyBza3lkZWxpcyJd"),r("aW1nW2FsdD0iRGVkaWt1b3RpLmx0IHNlcnZlcmlhaSJd"),r("aW1nW2FsdD0iSG9zdGluZ2FzIFNlcnZlcmlhaS5sdCJd")],estonian:[r("QVtocmVmKj0iaHR0cDovL3BheTRyZXN1bHRzMjQuZXUiXQ==")],fanboyAnnoyances:["#ac-lre-player",".navigate-to-top","#subscribe_popup",".newsletter_holder","#back-top"],fanboyAntiFacebook:[".util-bar-module-firefly-visible"],fanboyEnhancedTrackers:[".open.pushModal","#issuem-leaky-paywall-articles-zero-remaining-nag","#sovrn_container",'div[class$="-hide"][zoompage-fontsize][style="display: block;"]',".BlockNag__Card"],fanboySocial:["#FollowUs","#meteored_share","#social_follow",".article-sharer",".community__social-desc"],frellwitSwedish:[r("YVtocmVmKj0iY2FzaW5vcHJvLnNlIl1bdGFyZ2V0PSJfYmxhbmsiXQ=="),r("YVtocmVmKj0iZG9rdG9yLXNlLm9uZWxpbmsubWUiXQ=="),"article.category-samarbete",r("ZGl2LmhvbGlkQWRz"),"ul.adsmodern"],greekAdBlock:[r("QVtocmVmKj0iYWRtYW4ub3RlbmV0LmdyL2NsaWNrPyJd"),r("QVtocmVmKj0iaHR0cDovL2F4aWFiYW5uZXJzLmV4b2R1cy5nci8iXQ=="),r("QVtocmVmKj0iaHR0cDovL2ludGVyYWN0aXZlLmZvcnRobmV0LmdyL2NsaWNrPyJd"),"DIV.agores300","TABLE.advright"],hungarian:["#cemp_doboz",".optimonk-iframe-container",r("LmFkX19tYWlu"),r("W2NsYXNzKj0iR29vZ2xlQWRzIl0="),"#hirdetesek_box"],iDontCareAboutCookies:['.alert-info[data-block-track*="CookieNotice"]',".ModuleTemplateCookieIndicator",".o--cookies--container","#cookies-policy-sticky","#stickyCookieBar"],icelandicAbp:[r("QVtocmVmXj0iL2ZyYW1ld29yay9yZXNvdXJjZXMvZm9ybXMvYWRzLmFzcHgiXQ==")],latvian:[r("YVtocmVmPSJodHRwOi8vd3d3LnNhbGlkemluaS5sdi8iXVtzdHlsZT0iZGlzcGxheTogYmxvY2s7IHdpZHRoOiAxMjBweDsgaGVpZ2h0OiA0MHB4OyBvdmVyZmxvdzogaGlkZGVuOyBwb3NpdGlvbjogcmVsYXRpdmU7Il0="),r("YVtocmVmPSJodHRwOi8vd3d3LnNhbGlkemluaS5sdi8iXVtzdHlsZT0iZGlzcGxheTogYmxvY2s7IHdpZHRoOiA4OHB4OyBoZWlnaHQ6IDMxcHg7IG92ZXJmbG93OiBoaWRkZW47IHBvc2l0aW9uOiByZWxhdGl2ZTsiXQ==")],listKr:[r("YVtocmVmKj0iLy9hZC5wbGFuYnBsdXMuY28ua3IvIl0="),r("I2xpdmVyZUFkV3JhcHBlcg=="),r("YVtocmVmKj0iLy9hZHYuaW1hZHJlcC5jby5rci8iXQ=="),r("aW5zLmZhc3R2aWV3LWFk"),".revenue_unit_item.dable"],listeAr:[r("LmdlbWluaUxCMUFk"),".right-and-left-sponsers",r("YVtocmVmKj0iLmFmbGFtLmluZm8iXQ=="),r("YVtocmVmKj0iYm9vcmFxLm9yZyJd"),r("YVtocmVmKj0iZHViaXp6bGUuY29tL2FyLz91dG1fc291cmNlPSJd")],listeFr:[r("YVtocmVmXj0iaHR0cDovL3Byb21vLnZhZG9yLmNvbS8iXQ=="),r("I2FkY29udGFpbmVyX3JlY2hlcmNoZQ=="),r("YVtocmVmKj0id2Vib3JhbWEuZnIvZmNnaS1iaW4vIl0="),".site-pub-interstitiel",'div[id^="crt-"][data-criteo-id]'],officialPolish:["#ceneo-placeholder-ceneo-12",r("W2hyZWZePSJodHRwczovL2FmZi5zZW5kaHViLnBsLyJd"),r("YVtocmVmXj0iaHR0cDovL2Fkdm1hbmFnZXIudGVjaGZ1bi5wbC9yZWRpcmVjdC8iXQ=="),r("YVtocmVmXj0iaHR0cDovL3d3dy50cml6ZXIucGwvP3V0bV9zb3VyY2UiXQ=="),r("ZGl2I3NrYXBpZWNfYWQ=")],ro:[r("YVtocmVmXj0iLy9hZmZ0cmsuYWx0ZXgucm8vQ291bnRlci9DbGljayJd"),r("YVtocmVmXj0iaHR0cHM6Ly9ibGFja2ZyaWRheXNhbGVzLnJvL3Ryay9zaG9wLyJd"),r("YVtocmVmXj0iaHR0cHM6Ly9ldmVudC4ycGVyZm9ybWFudC5jb20vZXZlbnRzL2NsaWNrIl0="),r("YVtocmVmXj0iaHR0cHM6Ly9sLnByb2ZpdHNoYXJlLnJvLyJd"),'a[href^="/url/"]'],ruAd:[r("YVtocmVmKj0iLy9mZWJyYXJlLnJ1LyJd"),r("YVtocmVmKj0iLy91dGltZy5ydS8iXQ=="),r("YVtocmVmKj0iOi8vY2hpa2lkaWtpLnJ1Il0="),"#pgeldiz",".yandex-rtb-block"],thaiAds:["a[href*=macau-uta-popup]",r("I2Fkcy1nb29nbGUtbWlkZGxlX3JlY3RhbmdsZS1ncm91cA=="),r("LmFkczMwMHM="),".bumq",".img-kosana"],webAnnoyancesUltralist:["#mod-social-share-2","#social-tools",r("LmN0cGwtZnVsbGJhbm5lcg=="),".zergnet-recommend",".yt.btn-link.btn-md.btn"]}}function jw(r){var e=r===void 0?{}:r,t=e.debug;return z(this,void 0,void 0,function(){var n,i,a,o,u,s;return J(this,function(c){switch(c.label){case 0:return _w()?(n=Aw(),i=Object.keys(n),a=(s=[]).concat.apply(s,i.map(function(f){return n[f]})),[4,kw(a)]):[2,void 0];case 1:return o=c.sent(),t&&Dw(n,o),u=i.filter(function(f){var v=n[f],p=j(v.map(function(d){return o[d]}));return p>v.length*.6}),u.sort(),[2,u]}})})}function _w(){return Z()||oi()}function kw(r){var e;return z(this,void 0,void 0,function(){var t,n,i,a,s,o,u,s;return J(this,function(c){switch(c.label){case 0:for(t=document,n=t.createElement("div"),i=new Array(r.length),a={},Dl(n),s=0;s<r.length;++s)o=Yb(r[s]),o.tagName==="DIALOG"&&o.show(),u=t.createElement("div"),Dl(u),u.appendChild(o),n.appendChild(u),i[s]=o;c.label=1;case 1:return t.body?[3,3]:[4,nt(50)];case 2:return c.sent(),[3,1];case 3:t.body.appendChild(n);try{for(s=0;s<r.length;++s)i[s].offsetParent||(a[r[s]]=!0)}finally{(e=n.parentNode)===null||e===void 0||e.removeChild(n)}return[2,a]}})})}function Dl(r){r.style.setProperty("visibility","hidden","important"),r.style.setProperty("display","block","important")}function Dw(r,e){for(var t="DOM blockers debug:\n```",n=0,i=Object.keys(r);n<i.length;n++){var a=i[n];t+=`
`.concat(a,":");for(var o=0,u=r[a];o<u.length;o++){var s=u[o];t+=`
  `.concat(e[s]?"\u{1F6AB}":"\u27A1\uFE0F"," ").concat(s)}}console.log("".concat(t,"\n```"))}function Mw(){for(var r=0,e=["rec2020","p3","srgb"];r<e.length;r++){var t=e[r];if(matchMedia("(color-gamut: ".concat(t,")")).matches)return t}}function Fw(){if(Ml("inverted"))return!0;if(Ml("none"))return!1}function Ml(r){return matchMedia("(inverted-colors: ".concat(r,")")).matches}function Vw(){if(Fl("active"))return!0;if(Fl("none"))return!1}function Fl(r){return matchMedia("(forced-colors: ".concat(r,")")).matches}var Gw=100;function Ww(){if(matchMedia("(min-monochrome: 0)").matches){for(var r=0;r<=Gw;++r)if(matchMedia("(max-monochrome: ".concat(r,")")).matches)return r;throw new Error("Too high value")}}function Bw(){if(Pr("no-preference"))return 0;if(Pr("high")||Pr("more"))return 1;if(Pr("low")||Pr("less"))return-1;if(Pr("forced"))return 10}function Pr(r){return matchMedia("(prefers-contrast: ".concat(r,")")).matches}function Uw(){if(Vl("reduce"))return!0;if(Vl("no-preference"))return!1}function Vl(r){return matchMedia("(prefers-reduced-motion: ".concat(r,")")).matches}function Hw(){if(Gl("reduce"))return!0;if(Gl("no-preference"))return!1}function Gl(r){return matchMedia("(prefers-reduced-transparency: ".concat(r,")")).matches}function Zw(){if(Wl("high"))return!0;if(Wl("standard"))return!1}function Wl(r){return matchMedia("(dynamic-range: ".concat(r,")")).matches}var E=Math,A=function(){return 0};function Yw(){var r=E.acos||A,e=E.acosh||A,t=E.asin||A,n=E.asinh||A,i=E.atanh||A,a=E.atan||A,o=E.sin||A,u=E.sinh||A,s=E.cos||A,c=E.cosh||A,f=E.tan||A,v=E.tanh||A,p=E.exp||A,d=E.expm1||A,m=E.log1p||A,y=function(S){return E.pow(E.PI,S)},h=function(S){return E.log(S+E.sqrt(S*S-1))},g=function(S){return E.log(S+E.sqrt(S*S+1))},w=function(S){return E.log((1+S)/(1-S))/2},b=function(S){return E.exp(S)-1/E.exp(S)/2},C=function(S){return(E.exp(S)+1/E.exp(S))/2},Y=function(S){return E.exp(S)-1},X=function(S){return(E.exp(2*S)-1)/(E.exp(2*S)+1)},K=function(S){return E.log(1+S)};return{acos:r(.12312423423423424),acosh:e(1e308),acoshPf:h(1e154),asin:t(.12312423423423424),asinh:n(1),asinhPf:g(1),atanh:i(.5),atanhPf:w(.5),atan:a(.5),sin:o(-1e300),sinh:u(1),sinhPf:b(1),cos:s(10.000000000123),cosh:c(1),coshPf:C(1),tan:f(-1e300),tanh:v(1),tanhPf:X(1),exp:p(1),expm1:d(1),expm1Pf:Y(1),log1p:m(10),log1pPf:K(10),powPI:y(-100)}}var Xw="mmMwWLliI0fiflO&1",ri={default:[],apple:[{font:"-apple-system-body"}],serif:[{fontFamily:"serif"}],sans:[{fontFamily:"sans-serif"}],mono:[{fontFamily:"monospace"}],min:[{fontSize:"1px"}],system:[{fontFamily:"system-ui"}]};function $w(){return zw(function(r,e){for(var t={},n={},i=0,a=Object.keys(ri);i<a.length;i++){var o=a[i],u=ri[o],s=u[0],c=s===void 0?{}:s,f=u[1],v=f===void 0?Xw:f,p=r.createElement("span");p.textContent=v,p.style.whiteSpace="nowrap";for(var d=0,m=Object.keys(c);d<m.length;d++){var y=m[d],h=c[y];h!==void 0&&(p.style[y]=h)}t[o]=p,e.append(r.createElement("br"),p)}for(var g=0,w=Object.keys(ri);g<w.length;g++){var o=w[g];n[o]=t[o].getBoundingClientRect().width}return n})}function zw(r,e){return e===void 0&&(e=4e3),Jl(function(t,n){var i=n.document,a=i.body,o=a.style;o.width="".concat(e,"px"),o.webkitTextSizeAdjust=o.textSizeAdjust="none",Qr()?a.style.zoom="".concat(1/n.devicePixelRatio):Z()&&(a.style.zoom="reset");var u=i.createElement("div");return u.textContent=Hl([],Array(e/20<<0),!0).map(function(){return"word"}).join(" "),a.appendChild(u),r(i,a)},'<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">')}function Jw(){return navigator.pdfViewerEnabled}function Kw(){var r=new Float32Array(1),e=new Uint8Array(r.buffer);return r[0]=1/0,r[0]=r[0]-r[0],e[3]}function Qw(){var r=window.ApplePaySession;if(typeof r?.canMakePayments!="function")return-1;if(rS())return-3;try{return r.canMakePayments()?1:0}catch(e){return eS(e)}}var rS=$b;function eS(r){if(r instanceof Error&&r.name==="InvalidAccessError"&&/\bfrom\b.*\binsecure\b/i.test(r.message))return-2;throw r}function tS(){var r,e=document.createElement("a"),t=(r=e.attributionSourceId)!==null&&r!==void 0?r:e.attributionsourceid;return t===void 0?void 0:String(t)}var Kl=-1,Ql=-2,nS=new Set([10752,2849,2884,2885,2886,2928,2929,2930,2931,2932,2960,2961,2962,2963,2964,2965,2966,2967,2968,2978,3024,3042,3088,3089,3106,3107,32773,32777,32777,32823,32824,32936,32937,32938,32939,32968,32969,32970,32971,3317,33170,3333,3379,3386,33901,33902,34016,34024,34076,3408,3410,3411,3412,3413,3414,3415,34467,34816,34817,34818,34819,34877,34921,34930,35660,35661,35724,35738,35739,36003,36004,36005,36347,36348,36349,37440,37441,37443,7936,7937,7938]),iS=new Set([34047,35723,36063,34852,34853,34854,34229,36392,36795,38449]),aS=["FRAGMENT_SHADER","VERTEX_SHADER"],oS=["LOW_FLOAT","MEDIUM_FLOAT","HIGH_FLOAT","LOW_INT","MEDIUM_INT","HIGH_INT"],rv="WEBGL_debug_renderer_info",uS="WEBGL_polygon_mode";function sS(r){var e,t,n,i,a,o,u=r.cache,s=ev(u);if(!s)return Kl;if(!nv(s))return Ql;var c=tv()?null:s.getExtension(rv);return{version:((e=s.getParameter(s.VERSION))===null||e===void 0?void 0:e.toString())||"",vendor:((t=s.getParameter(s.VENDOR))===null||t===void 0?void 0:t.toString())||"",vendorUnmasked:c?(n=s.getParameter(c.UNMASKED_VENDOR_WEBGL))===null||n===void 0?void 0:n.toString():"",renderer:((i=s.getParameter(s.RENDERER))===null||i===void 0?void 0:i.toString())||"",rendererUnmasked:c?(a=s.getParameter(c.UNMASKED_RENDERER_WEBGL))===null||a===void 0?void 0:a.toString():"",shadingLanguageVersion:((o=s.getParameter(s.SHADING_LANGUAGE_VERSION))===null||o===void 0?void 0:o.toString())||""}}function cS(r){var e=r.cache,t=ev(e);if(!t)return Kl;if(!nv(t))return Ql;var n=t.getSupportedExtensions(),i=t.getContextAttributes(),a=[],o=[],u=[],s=[],c=[];if(i)for(var f=0,v=Object.keys(i);f<v.length;f++){var p=v[f];o.push("".concat(p,"=").concat(i[p]))}for(var d=Bl(t),m=0,y=d;m<y.length;m++){var h=y[m],g=t[h];u.push("".concat(h,"=").concat(g).concat(nS.has(g)?"=".concat(t.getParameter(g)):""))}if(n)for(var w=0,b=n;w<b.length;w++){var C=b[w];if(!(C===rv&&tv()||C===uS&&fS())){var Y=t.getExtension(C);if(!Y){a.push(C);continue}for(var X=0,K=Bl(Y);X<K.length;X++){var h=K[X],g=Y[h];s.push("".concat(h,"=").concat(g).concat(iS.has(g)?"=".concat(t.getParameter(g)):""))}}}for(var S=0,te=aS;S<te.length;S++)for(var Nr=te[S],ne=0,li=oS;ne<li.length;ne++){var vi=li[ne],mv=lS(t,Nr,vi);c.push("".concat(Nr,".").concat(vi,"=").concat(mv.join(",")))}return s.sort(),u.sort(),{contextAttributes:o,parameters:u,shaderPrecisions:c,extensions:n,extensionParameters:s,unsupportedExtensions:a}}function ev(r){if(r.webgl)return r.webgl.context;var e=document.createElement("canvas"),t;e.addEventListener("webglCreateContextError",function(){return t=void 0});for(var n=0,i=["webgl","experimental-webgl"];n<i.length;n++){var a=i[n];try{t=e.getContext(a)}catch{}if(t)break}return r.webgl={context:t},t}function lS(r,e,t){var n=r.getShaderPrecisionFormat(r[e],r[t]);return n?[n.rangeMin,n.rangeMax,n.precision]:[]}function Bl(r){var e=Object.keys(r.__proto__);return e.filter(vS)}function vS(r){return typeof r=="string"&&!r.match(/[^A-Z0-9_x]/)}function tv(){return zl()}function fS(){return Qr()||Z()}function nv(r){return typeof r.getParameter=="function"}function dS(){var r,e=oi()||Z();return e?window.AudioContext&&(r=new AudioContext().baseLatency)!==null&&r!==void 0?r:-1:-2}var pS={fonts:Kb,domBlockers:jw,fontPreferences:$w,audio:Gb,screenFrame:ww,canvas:rw,osCpu:lw,languages:vw,colorDepth:fw,deviceMemory:dw,screenResolution:pw,hardwareConcurrency:Sw,timezone:Ew,sessionStorage:qw,localStorage:Cw,indexedDB:xw,openDatabase:Tw,cpuClass:Ow,platform:Rw,plugins:Qb,touchSupport:cw,vendor:Pw,vendorFlavors:Lw,cookiesEnabled:Nw,colorGamut:Mw,invertedColors:Fw,forcedColors:Vw,monochrome:Ww,contrast:Bw,reducedMotion:Uw,reducedTransparency:Hw,hdr:Zw,math:Yw,pdfViewerEnabled:Jw,architecture:Kw,applePay:Qw,privateClickMeasurement:tS,audioBaseLatency:dS,webGlBasics:sS,webGlExtensions:cS};function mS(r){return Nb(pS,r,[])}var hS="$ if upgrade to Pro: https://fpjs.dev/pro";function gS(r){var e=yS(r),t=bS(e);return{score:e,comment:hS.replace(/\$/g,"".concat(t))}}function yS(r){if(oi())return .4;if(Z())return ai()&&!(ee()&&re())?.5:.3;var e="value"in r.platform?r.platform.value:"";return/^Win/.test(e)?.6:/^Mac/.test(e)?.5:.7}function bS(r){return Xl(.99+.01*r,1e-4)}function wS(r){for(var e="",t=0,n=Object.keys(r).sort();t<n.length;t++){var i=n[t],a=r[i],o="error"in a?"error":JSON.stringify(a.value);e+="".concat(e?"|":"").concat(i.replace(/([:|\\])/g,"\\$1"),":").concat(o)}return e}function iv(r){return JSON.stringify(r,function(e,t){return t instanceof Error?Ob(t):t},2)}function av(r){return Tb(wS(r))}function SS(r){var e,t=gS(r);return{get visitorId(){return e===void 0&&(e=av(this.components)),e},set visitorId(n){e=n},confidence:t,components:r,version:Zl}}function ES(r){return r===void 0&&(r=50),yb(r,r*2)}function IS(r,e){var t=Date.now();return{get:function(n){return z(this,void 0,void 0,function(){var i,a,o;return J(this,function(u){switch(u.label){case 0:return i=Date.now(),[4,r()];case 1:return a=u.sent(),o=SS(a),(e||n?.debug)&&console.log("Copy the text below to get the debug data:\n\n```\nversion: ".concat(o.version,`
userAgent: `).concat(navigator.userAgent,`
timeBetweenLoadAndGet: `).concat(i-t,`
visitorId: `).concat(o.visitorId,`
components: `).concat(iv(a),"\n```")),[2,o]}})})}}}function qS(){if(!(window.__fpjs_d_m||Math.random()>=.001))try{var r=new XMLHttpRequest;r.open("get","https://m1.openfpcdn.io/fingerprintjs/v".concat(Zl,"/npm-monitoring"),!0),r.send()}catch(e){console.error(e)}}function CS(r){var e;return r===void 0&&(r={}),z(this,void 0,void 0,function(){var t,n,i;return J(this,function(a){switch(a.label){case 0:return(!((e=r.monitoring)!==null&&e!==void 0)||e)&&qS(),t=r.delayFallback,n=r.debug,[4,ES(t)];case 1:return a.sent(),i=mS({cache:{},debug:n}),[2,IS(i,n)]}})})}var xS={load:CS,hashComponents:av,componentsToDebugString:iv},ov={clientId:"",environment:"sandbox",region:"default"},uv,sv,TS=r=>{ov={...r}},ui=()=>ov,Ul=r=>{r&&(uv={...r})},cv=()=>uv,OS=r=>{r&&(sv=r)},RS=()=>sv,PS=r=>r?["ca","in","au"].includes(r):!1,lv=()=>{let{environment:r,region:e}=ui(),t=r==="sandbox";if(PS(e)&&t)return"api.sandbox.sardine.ai";var n=e==="default"?"":e||"";return n=n?`${n}.`:"",t?`api.sandbox.${n}sardine.ai`:`api.${n}sardine.ai`},LS=r=>{let e=cv();if(!e)return!0;let t=["enableBiometrics","enableGeoLocation","enablePortScanning","parentSessionKey","partnerId"];for(let n of t)if(n in r&&r[n]!==e[n])return!0;return!1},NS=()=>{let{apiSubdomain:r}=ui(),e=lv();return`https://${r||e}/assets/loader.min.js`},AS=r=>{TS(r)},vv=async r=>new Promise(function(e,t){var n;let{clientId:i,environment:a,region:o,apiSubdomain:u,pixelSubdomain:s}=ui();if(!i){t({status:"error",error:new Error("clientId is required")});return}let c=RS(),{customerId:f,sessionKey:v,flow:p,fields:d,enableBiometrics:m,enableGeoLocation:y,enablePortScanning:h,parentSessionKey:g,partnerId:w}=r;if(c&&!LS(r))c.updateConfig({flow:p,userIdHash:f,sessionKey:v,fields:d}),Ul(r),e({status:"success"});else{let X=NS(),K=document.querySelector(`script[src="${X}"]`);K&&K.remove();let S=a==="sandbox";var b=lv();let te=u||b;var C=document.createElement("script");C.type="text/javascript",C.async=!0,C.src=`https://${te}/assets/loader.min.js`,C.onload=function(){let Nr=window._Sardine.createContext({clientId:i,sessionKey:v,userIdHash:f,flow:p||location.pathname,environment:S?"sandbox":"production",parentElement:document.body,partnerId:w,parentSessionKey:g,enablePortScanning:h,enableBiometrics:m||!0,enableGeoLocation:y,apiSubdomain:u,pixelSubdomain:s,fields:d,onDeviceResponse:function(ne){e({status:"success"})}});Ul(r),OS(Nr)},C.onerror=function(Nr){t({status:"error",error:new Error("Failed to load Sardine SDK: ["+C.src+"]")})};var Y=document.getElementsByTagName("script")[0];(n=Y.parentNode)==null||n.insertBefore(C,Y)}}),jS=()=>cv();async function fv(r){let{apiBaseUrl:e,authToken:t,fingerprint:n,customerId:i,additionalHeaders:a,timeout:o=1e4,internal:u=!1}=r;if(!e)throw new Error("apiBaseUrl is required for getSessionTag");if(u&&!t)throw new Error("authToken is required for getSessionTag");if(!u&&!i)throw new Error("customerId is required for getSessionTag");let s=u?`${e}/caas/v2/get-session-tag`:`${e}/pub/get-session-tag?accountId=${i}`,c={"Content-Type":"application/json","x-device-fingerprint":n,...u&&t?{Authorization:`Bearer ${t}`}:{},...a};try{let f=new AbortController,v=setTimeout(()=>f.abort(),o),p=await fetch(s,{method:"GET",headers:c,signal:f.signal});if(clearTimeout(v),!p.ok)throw new Error(`Failed to retrieve session tag: HTTP ${p.status} ${p.statusText}`);let d=await p.json();if(d.errorResponse!==null)throw new Error(`Session tag endpoint returned an error: ${JSON.stringify(d.errorResponse)}`);if(!d.data||!d.data.webSessionID)throw new Error("Invalid response format: missing data or webSessionID");return Lr=d.data.webSessionID,await vv({sessionKey:d.data.webSessionID}),d.data}catch(f){throw f instanceof TypeError&&f.message==="Failed to fetch"?new Error("Network error: Unable to reach the API endpoint"):f instanceof DOMException&&f.name==="AbortError"?new Error(`Request timeout: Session tag request exceeded ${o}ms`):f}}function _S(){return jS()??{}}var Lr;function dv(){Lr=void 0}async function si(r){let e=r.sessionKey;e||(Lr?e=Lr:e=await(await xS.load()).get().then(i=>i.visitorId)),Lr=e;let t=_S();return await vv({...t,...r,sessionKey:e})}function kS(r,e){if(!["test","prod"].includes(r))throw new Error('Invalid mode. Use "test" or "prod".');if(!e)throw new Error("Client ID is required!")}async function pv({mode:r,clientId:e,sessionKey:t,...n}){return kS(r,e),AS({clientId:e,environment:r==="test"?"sandbox":"production"}),t&&(Lr=t),await si({sessionKey:t,...n})}var ci=(r=>(r.Onboarding="customer-onboarding",r.CardTransaction="card-transaction",r.CardLinking="payment-method-linking",r))(ci||{});return Ev(DS);})();
sdk=coinme}return sdk}}})();

(function (global) {
    'use strict';

    // ------------------------------------------------------------------ config

    // Single source of truth for every provider-specific value the agnostic plumbing
    // consumes: the embed script, the iframe origins to allowlist, and the iframe `allow`
    // permissions the provider's in-frame flow requires. Adding a provider is one entry
    // here — requiredCsp(), environment inference, and the public API never change.
    // The `/web` subpath is load-bearing: the package's root export ("." -> dist/api.mjs) is the
    // REST API client and exports no <banxa-primer-checkout>; only `./web` registers the component.
    // Loading the root returned a module with no registerBanxaPrimerCheckout and every mount died
    // with sdk_unavailable. Version-pinned, but note jsDelivr's `/+esm` bundles are generated per
    // request (their banner says "Do NOT use SRI with dynamically generated files"), so the pin fixes
    // the source, not the delivered bytes — vendoring + hashing, as the mobile SDKs do, is the
    // follow-up.
    const BANXA_SDK_MODULE =
        'https://cdn.jsdelivr.net/npm/@banxa-official/javascript-native-payments-sdk@1.0.1/web/+esm';

    const STRIPE_HOSTS = {
        scriptSrc: ['https://js.stripe.com', 'https://*.js.stripe.com'],
        frameSrc: [
            'https://js.stripe.com',
            'https://*.js.stripe.com',
            'https://hooks.stripe.com',
            'https://link.com',
            'https://*.link.com',
        ],
        connectSrc: ['https://api.stripe.com', 'https://link.com', 'https://*.link.com'],
        imgSrc: ['https://*.stripe.com', 'https://*.link.com'],
        iframeAllow: ['payment', 'camera'],
        paymentActions: true,
    };

    // Coinme card. The vendored Vault SDK loads VGS Collect from VGS's CDN (js3 is its fallback),
    // whose secure-field frames submit to Coinme's vault ingress and report to VGS's analytics host.
    // The vendored Risk SDK calls Coinme's risk API, loads Sardine's device script from Sardine, and
    // lets FingerprintJS send its sampled monitoring request.
    function coinmeHosts(vaultIngress, riskApi) {
        const vgs = ['https://js.verygoodvault.com', 'https://js3.verygoodvault.com'];
        const sardine = 'https://*.sardine.ai';
        return {
            scriptSrc: [...vgs, sardine],
            frameSrc: [...vgs, sardine],
            connectSrc: [
                ...vgs,
                'https://vgs-collect-keeper.apps.verygood.systems',
                vaultIngress,
                riskApi,
                sardine,
                'https://m1.openfpcdn.io',
            ],
            imgSrc: [sardine],
            iframeAllow: [],
            paymentActions: true,
        };
    }

    const PROVIDER_HOSTS = {
        MERCURYO: {
            sandbox: {
                scriptSrc: 'https://sandbox-widget.mrcr.io/embed.2.1.js',
                frameSrc: ['https://sandbox-widget.mrcr.io', 'https://sandbox-exchange.mrcr.io'],
                iframeAllow: ['camera'], // Mercuryo's in-iframe KYC liveness
            },
            production: {
                scriptSrc: 'https://widget.mercuryo.io/embed.2.1.js',
                frameSrc: ['https://widget.mercuryo.io', 'https://exchange.mercuryo.io'],
                iframeAllow: ['camera'],
            },
        },
        // Uphold card — the widget SDK is INLINED into this file (globalThis.MeldUpholdWidget.
        // PaymentWidget, installed at load), so there is NO external/extra script to load and no
        // scriptSrc to declare — the widget runs as part of the SDK's own JS (already covered by
        // whatever source the integrator loads @meldcrypto/sdk from). frameSrc is Uphold's
        // payment-widget host — the origin the PaymentWidget builds its iframe against. camera is
        // needed for the widget's in-iframe KYC liveness.
        UPHOLD: {
            sandbox: {
                frameSrc: ['https://payment-widget.enterprise.sandbox.uphold.com'],
                iframeAllow: ['camera'],
            },
            production: {
                frameSrc: ['https://payment-widget.enterprise.uphold.com'],
                iframeAllow: ['camera'],
            },
        },
        // Banxa card — the capture surface is Primer's, rendered by Banxa's own
        // <banxa-primer-checkout> web component. Unlike Uphold's widget (inlined above) the bundle
        // is ~1.3MB once Primer is included, which is far too large to inline into this file, and
        // unlike Mercuryo there is no Banxa-owned CDN build published — the SDK ships to npm only.
        // So it is loaded as an ES module from jsDelivr, whose /+esm endpoint resolves the package's
        // bare `@primer-io/primer-js` import.
        //
        // TODO(banxa): ask Banxa for a versioned, provider-owned CDN URL. Loading a payment surface
        // from a third-party CDN is a supply-chain dependency we would not choose deliberately, and
        // pinning the exact version below is the only thing currently limiting it.
        //
        // frameSrc is Primer's, not Banxa's: the component mounts Primer's hosted card inputs, so
        // those are the origins an integrator's CSP must allow.
        BANXA: {
            sandbox: {
                moduleSrc: BANXA_SDK_MODULE,
                frameSrc: ['https://sdk.primer.io', 'https://sdk.sandbox.primer.io'],
                iframeAllow: [],
            },
            production: {
                moduleSrc: BANXA_SDK_MODULE,
                frameSrc: ['https://sdk.primer.io', 'https://sdk.production.primer.io'],
                iframeAllow: [],
            },
        },
        // Stripe's crypto onramp runtime and the Stripe.js and Link hosts it draws on. Payment actions
        // add the Meld API to connect-src unless they go through a proxy.
        STRIPE: {
            sandbox: STRIPE_HOSTS,
            production: STRIPE_HOSTS,
        },
        // One host for both environments; sandbox links are marked by the order, not the host.
        COINBASEPAY: {
            sandbox: { frameSrc: ['https://pay.coinbase.com'], iframeAllow: ['payment'] },
            production: { frameSrc: ['https://pay.coinbase.com'], iframeAllow: ['payment'] },
        },
        COINME: {
            sandbox: coinmeHosts(
                'https://secure.payments-stage.coinme.com',
                'https://caas-staging.coinme.com',
            ),
            production: coinmeHosts(
                'https://secure.payments.coinme.com',
                'https://caas.coinme.com',
            ),
        },
    };

    const ACTION_API_BASES = {
        sandbox: 'https://api-sb.meld.io',
        qa: 'https://api-qa.meld.io',
        production: 'https://api.meld.io',
    };
    const ACTION_PROXY_PATH = /^\/(?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_-]+$/;

    let config = { environment: 'sandbox' };
    // The currently-mounted session, so a duplicate mount() tears the previous one down instead of leaking
    // its global window 'message' listener + iframe (M10).
    let activeSession = null;

    function configure(options) {
        const next = Object.assign({}, config, options || {});
        if (
            next.actionProxyUrl != null &&
            !(
                typeof next.actionProxyUrl === 'string' &&
                ACTION_PROXY_PATH.test(next.actionProxyUrl)
            )
        ) {
            throw new TypeError("actionProxyUrl must be a same-origin path such as '/api/meld'.");
        }
        config = next;
    }

    /** Provider script hosts have no QA tier, so QA loads the sandbox scripts. The order's own provider environment comes from its account's credentials. */
    function providerEnvironment() {
        const environment = config.environment || 'sandbox';
        return environment === 'qa' ? 'sandbox' : environment;
    }

    /**
     * Resolve which environment a signed widget URL belongs to by matching its host
     * against the provider's registered origins — no hardcoded host suffixes, so it
     * works for any provider in the registry. The signed URL only works against its own
     * environment, so the order is authoritative and overrides Meld.configure({environment});
     * this prevents loading the sandbox embed script against a production order when an
     * integrator forgets configure(). Falls back to the configured environment when the host
     * isn't recognized.
     */
    function inferEnvironment(provider, widgetUrlHost) {
        const origin = 'https://' + widgetUrlHost;
        const envs = PROVIDER_HOSTS[provider] || {};
        const match = Object.keys(envs).find((env) => envs[env].frameSrc.includes(origin));
        return match || providerEnvironment();
    }

    function isRegisteredWidgetUrl(provider, widgetUrl) {
        if (!widgetUrl) {
            return false;
        }
        let url;
        try {
            url = new URL(widgetUrl);
            if (url.protocol !== 'https:' || url.username || url.password) return false;
        } catch (e) {
            return false;
        }
        const envs = PROVIDER_HOSTS[provider] || {};
        return Object.keys(envs).some((env) => envs[env].frameSrc.includes(url.origin));
    }

    // --------------------------------------------------------------- utilities
    // Provider-agnostic plumbing shared by all adapters.

    const scriptCache = new Map(); // scriptSrc -> Promise<void>

    /**
     * A <script> element's onerror exposes no status or reason (same-origin-policy
     * opacity), so probe the URL with a no-cors fetch to split the failure into the
     * two real-world cases: an opaque response resolving means the server DID respond
     * — i.e. an HTTP error such as an IP-allowlist 403; a rejected fetch means the
     * request never left the browser (ad-blocker, DNS, offline).
     */
    function diagnoseScriptFailure(src) {
        return fetch(src, { mode: 'no-cors', cache: 'no-store' })
            .then(
                () =>
                    'server responded but the script failed to load — likely an HTTP error' +
                    ' (provider IP allowlist?)',
            )
            .catch(
                (e) =>
                    'request blocked before reaching the server' +
                    ' (ad-blocker, DNS, or offline): ' +
                    e.message,
            );
    }

    /**
     * `payload.serviceProvider` from the headless order response. Read defensively: it is required
     * on the request and so always present there, but the mid-flow authorize-session response
     * (Uphold) is a different shape that carries no payload.
     */
    function serviceProviderOf(order) {
        return order && order.payload ? order.payload.serviceProvider : undefined;
    }

    /** `options.module` loads an ES module; `options.timeoutMs` gives up on a script that hangs. */
    function loadScriptOnce(src, options) {
        if (scriptCache.has(src)) {
            return scriptCache.get(src);
        }
        const { module: isModule = false, timeoutMs = 0 } = options || {};
        const promise = new Promise((resolve, reject) => {
            const script = document.createElement('script');
            if (isModule) script.type = 'module';
            script.src = src;
            script.async = true;
            let timer = null;
            function fail(diagnosis) {
                const err = new Error('Failed to load provider script: ' + src + ' — ' + diagnosis);
                err.detail = diagnosis;
                reject(err);
            }
            // Evict on failure so the next mount retries instead of replaying the cached
            // rejection (a transient block — VPN flap, allowlist, ad-blocker — would otherwise
            // poison the whole page session).
            function evict() {
                clearTimeout(timer);
                script.onload = null;
                script.onerror = null;
                scriptCache.delete(src);
                script.remove();
            }
            // NOTE: a production release pins the provider script version and ships a
            // subresource-integrity hash manifest. The POC loads it bare.
            script.onload = () => {
                clearTimeout(timer);
                resolve();
            };
            script.onerror = () => {
                evict();
                diagnoseScriptFailure(src).then(fail);
            };
            if (timeoutMs > 0) {
                timer = setTimeout(() => {
                    evict();
                    fail('no response within ' + timeoutMs + ' ms');
                }, timeoutMs);
            }
            document.head.appendChild(script);
        });
        scriptCache.set(src, promise);
        return promise;
    }

    function safeCall(fn, name, payload) {
        if (typeof fn !== 'function') return;
        try {
            fn(payload);
        } catch (e) {
            // Integrator handler errors must not break the widget lifecycle.
            console.error('[meld-sdk] handler ' + name + ' threw', e);
        }
    }

    /** Wraps handlers with own overrides; every other callback, own or inherited, stays reachable. */
    function inheritWith(handlers, overrides) {
        return Object.create(handlers, Object.getOwnPropertyDescriptors(overrides));
    }

    /**
     * Collapses a provider's "the customer is done paying" moment into exactly one
     * onPaymentSubmitted per mount.
     *
     * Providers disagree on how that moment arrives. Uphold's authorize widget sends only
     * `complete` and never a status. Hosted-link Apple Pay sends commit_success AND polling_start
     * — both meaning submitted — then polling_success as a `completed` status. Mercuryo's card
     * widget sends "payment finished" and a `paid` status as two unrelated messages with no
     * ordering between them. Left alone, that asymmetry lands on the integrator, who has to dedupe
     * terminal handling or watch it run twice.
     *
     * A terminal failed/cancelled status, a cancel, or a non-recoverable error closes the gate
     * without firing, so a failure is never followed by a submission. A recoverable error does not:
     * the mount is still alive and the customer may yet pay.
     *
     * onStatusChange is passed straight through — a provider that genuinely reports `completed`
     * still reports it, and the status lands before the synthesized onPaymentSubmitted.
     */
    function gateTerminalEvents(handlers) {
        let closed = false;
        function open() {
            if (closed) return false;
            closed = true;
            return true;
        }
        function submit(payload) {
            safeCall(handlers.onPaymentSubmitted, 'onPaymentSubmitted', payload);
        }
        return inheritWith(handlers, {
            onPaymentSubmitted: function (payload) {
                if (open()) submit(payload);
            },
            onStatusChange: function (payload) {
                safeCall(handlers.onStatusChange, 'onStatusChange', payload);
                const status = payload && payload.status;
                if (status === 'completed') {
                    if (open()) submit({ orderId: payload && payload.orderId });
                } else if (status === 'failed' || status === 'cancelled') {
                    closed = true;
                }
            },
            onCancel: function (payload) {
                closed = true;
                safeCall(handlers.onCancel, 'onCancel', payload);
            },
            onError: function (payload) {
                if (!(payload && payload.recoverable)) closed = true;
                safeCall(handlers.onError, 'onError', payload);
            },
        });
    }

    /** Every onError payload names the mounted order's payment method. */
    function nameErrorPaymentMethod(handlers, paymentMethodType) {
        return inheritWith(handlers, {
            onError: function (payload) {
                safeCall(
                    handlers.onError,
                    'onError',
                    Object.assign({}, payload, { paymentMethodType }),
                );
            },
        });
    }

    // The MeldErrorCode set every Meld SDK shares, published as Meld.ErrorCode. The provider's own
    // event or action code travels in `detail`.
    const ERROR_CODES = Object.freeze({
        PRESENTATION_FAILED: 'PRESENTATION_FAILED',
        PAYMENT_METHOD_UNAVAILABLE: 'PAYMENT_METHOD_UNAVAILABLE',
        PAYMENT_REJECTED: 'PAYMENT_REJECTED',
        ORDER_STATE_CHANGED: 'ORDER_STATE_CHANGED',
        VERIFICATION_PENDING: 'VERIFICATION_PENDING',
        PAYMENT_OUTCOME_UNKNOWN: 'PAYMENT_OUTCOME_UNKNOWN',
        PROVIDER_LOAD_FAILED: 'PROVIDER_LOAD_FAILED',
    });
    const NO_ATTEMPT_CODES = new Set([
        ERROR_CODES.PRESENTATION_FAILED,
        ERROR_CODES.PAYMENT_METHOD_UNAVAILABLE,
        ERROR_CODES.PAYMENT_REJECTED,
        ERROR_CODES.ORDER_STATE_CHANGED,
        ERROR_CODES.VERIFICATION_PENDING,
    ]);

    // What onError says for each code when the adapter has nothing more specific. The provider's
    // own message never reaches it.
    const ERROR_MESSAGES = Object.freeze({
        PRESENTATION_FAILED:
            "The provider's checkout could not be shown. No payment was attempted.",
        PAYMENT_METHOD_UNAVAILABLE:
            'This payment method is not available for this checkout. Offer another option.',
        PAYMENT_REJECTED: 'The payment was declined. Choose another payment option.',
        ORDER_STATE_CHANGED: 'The provider no longer accepts this order. No payment was attempted.',
        VERIFICATION_PENDING:
            "The provider is reviewing the customer's verification. No payment was attempted.",
        PAYMENT_OUTCOME_UNKNOWN:
            'The payment outcome is not known yet. Track the existing order without paying again.',
    });

    /** False only for codes that say no attempt exists; any other code, known or not, may follow one. */
    function attemptMayExist(code) {
        return !NO_ATTEMPT_CODES.has(code);
    }

    /** A non-recoverable onError payload in the shared vocabulary. */
    function meldError(orderId, code, detail, message) {
        const error = { orderId, code, message: message || ERROR_MESSAGES[code] };
        if (detail !== undefined) error.detail = detail;
        error.recoverable = false;
        return error;
    }

    function emit(handlers, name, payload) {
        if (handlers) {
            safeCall(handlers[name], name, payload);
        }
    }

    /**
     * Once-only onReady synthesizer — a provider may not emit a native ready event,
     * so the adapter synthesizes one. Returns a fire() the adapter calls from
     * whichever signal arrives first: a native ready event, a load heuristic, or a
     * fallback timer.
     */
    function readySynthesizer(order, handlers, isUnmounted) {
        let fired = false;
        return function fire() {
            if (!fired && !isUnmounted()) {
                fired = true;
                emit(handlers, 'onReady', { orderId: order.id });
            }
        };
    }

    function clearChildren(el) {
        while (el.firstChild) {
            el.removeChild(el.firstChild);
        }
    }

    function hasOwn(object, key) {
        return Object.prototype.hasOwnProperty.call(object, key);
    }

    function isPlainObject(value) {
        return !!value && typeof value === 'object' && !Array.isArray(value);
    }

    function utf8Length(text) {
        return new TextEncoder().encode(text).length;
    }

    // --------------------------------------------------------- payment actions
    // The order-scoped transport for `paymentActions`, a port of the iOS PaymentActionClient. It
    // never interprets provider state and never retains the bearer, request body or response body.

    const ACTION_BODY_LIMIT = 65536;
    const ACTION_TIMEOUT_MS = 30000;
    const ACTION_KEY = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    const ACTION_NAME = /^[A-Z][A-Z0-9_]{0,63}$/;
    const ACTION_FAILURE_STATUS = Object.freeze({
        INVALID_REQUEST: 400,
        AUTHORIZATION_REQUIRED: 401,
        STATE_NOT_FOUND: 404,
        REQUEST_CONFLICT: 409,
        ORDER_STATE_CHANGED: 409,
        CONCURRENT_STATE_CHANGE: 409,
        OPERATION_IN_FLIGHT: 425,
        PROVIDER_REJECTED: 422,
        PROVIDER_RATE_LIMITED: 429,
        PROVIDER_UNAVAILABLE: 502,
        INVALID_PROVIDER_RESPONSE: 502,
        OUTCOME_UNKNOWN: 503,
    });
    const actionBearers = new WeakMap();

    function actionError(kind, details) {
        const extra = details || {};
        const error = new Error(
            'Payment action failed: ' +
                kind +
                (extra.code ? ' ' + extra.code : '') +
                (extra.status ? ' (HTTP ' + extra.status + ')' : ''),
        );
        error.name = 'MeldPaymentActionError';
        error.kind = kind;
        if (extra.code) error.code = extra.code;
        if (extra.status) error.status = extra.status;
        return error;
    }

    /** RFC 6901, over own properties only. */
    function resolvePointer(pointer, root) {
        if (typeof pointer !== 'string' || !pointer.startsWith('/') || pointer.length > 1024) {
            return undefined;
        }
        let current = root;
        for (const encoded of pointer.slice(1).split('/')) {
            if (/~(?:[^01]|$)/.test(encoded)) return undefined;
            const key = encoded.replace(/~1/g, '/').replace(/~0/g, '~');
            if (Array.isArray(current)) {
                if (!/^(?:0|[1-9][0-9]*)$/.test(key) || Number(key) >= current.length) {
                    return undefined;
                }
                current = current[Number(key)];
            } else if (isPlainObject(current) && hasOwn(current, key)) {
                current = current[key];
            } else {
                return undefined;
            }
        }
        return current;
    }

    function paymentActionDescriptor(order) {
        const invalid = () => actionError('invalidDescriptor');
        const base = ACTION_API_BASES[config.environment || 'sandbox'];
        const raw = order && order.paymentActions;
        if (
            !base ||
            !isPlainObject(raw) ||
            raw.version !== 1 ||
            typeof raw.endpoint !== 'string' ||
            typeof order.id !== 'string' ||
            !order.id
        ) {
            throw invalid();
        }
        const origin = new URL(base).origin;
        let url;
        try {
            url = new URL(raw.endpoint, base);
        } catch (e) {
            throw invalid();
        }
        // Comparing the declared string with its parsed form rejects userinfo, ports, queries,
        // fragments, dot segments and backslashes in one place.
        if (
            url.origin !== origin ||
            (raw.endpoint !== url.pathname && raw.endpoint !== origin + url.pathname)
        ) {
            throw invalid();
        }
        const parts = url.pathname.split('/');
        const declaredProvider = serviceProviderOf(order);
        if (
            parts.length !== 8 ||
            parts.slice(0, 4).join('/') !== '/crypto/order/headless' ||
            (parts[4] !== 'onramp' && parts[4] !== 'offramp') ||
            !ACTION_NAME.test(parts[5]) ||
            parts[6] !== order.id ||
            parts[7] !== 'actions' ||
            (declaredProvider != null && declaredProvider !== parts[5])
        ) {
            throw invalid();
        }
        const bearer = resolvePointer(raw.bearerTokenPointer, order);
        if (typeof bearer !== 'string' || !/^[\x21-\x7e]{1,16384}$/.test(bearer)) {
            throw invalid();
        }
        if (!Array.isArray(raw.operations) || raw.operations.length === 0) throw invalid();
        const operations = Object.create(null);
        for (const item of raw.operations) {
            if (
                !isPlainObject(item) ||
                typeof item.operation !== 'string' ||
                !ACTION_NAME.test(item.operation) ||
                typeof item.idempotencyKeyRequired !== 'boolean' ||
                item.operation in operations
            ) {
                throw invalid();
            }
            operations[item.operation] = item.idempotencyKeyRequired;
        }
        const descriptor = Object.freeze({
            endpoint: url.pathname,
            identity: origin + url.pathname,
            operations: Object.freeze(operations),
            toString: () => '[MeldPaymentActions REDACTED]',
        });
        actionBearers.set(descriptor, bearer);
        return descriptor;
    }

    /** Body text, or null when it exceeds the cap. Buffered whole, as iOS does. */
    async function readBoundedText(response) {
        const headers = response.headers;
        const declared = Number(
            headers && typeof headers.get === 'function' && headers.get('content-length'),
        );
        if (declared > ACTION_BODY_LIMIT) return null;
        const text = await response.text();
        return utf8Length(text) > ACTION_BODY_LIMIT ? null : text;
    }

    function fetchActionTransport(mode, credentials) {
        return async function (request) {
            const response = await fetch(request.url, {
                method: 'POST',
                mode,
                credentials,
                cache: 'no-store',
                redirect: 'error',
                referrerPolicy: 'no-referrer',
                headers: request.headers,
                body: request.body,
                signal: request.signal,
            });
            return { status: response.status, body: await readBoundedText(response) };
        };
    }

    // Stand-in for the network, set through Meld.__setActionTransport by tests and by the native SDKs'
    // WebView hosts. It gets the request the SDK would send and resolves to { status, body }; the SDK
    // still validates both.
    let actionTransportOverride = null;

    /** Chosen once per client, so a later configure() cannot retarget an order mid-flow. */
    function actionTransportFor(descriptor) {
        if (actionTransportOverride) {
            const custom = actionTransportOverride;
            return {
                url: descriptor.identity,
                run: async (request) => {
                    const result = await custom(request);
                    const body = result && result.body;
                    return {
                        status: result && result.status,
                        body:
                            typeof body === 'string' && utf8Length(body) <= ACTION_BODY_LIMIT
                                ? body
                                : null,
                    };
                },
            };
        }
        if (config.actionProxyUrl) {
            const location = global.location;
            if (!location || !/^https?:$/.test(location.protocol)) {
                throw actionError('invalidDescriptor');
            }
            return {
                url: location.origin + config.actionProxyUrl + descriptor.endpoint,
                run: fetchActionTransport('same-origin', 'same-origin'),
            };
        }
        return { url: descriptor.identity, run: fetchActionTransport('cors', 'omit') };
    }

    function parseJsonObject(text) {
        if (typeof text !== 'string') return null;
        try {
            const value = JSON.parse(text);
            return isPlainObject(value) ? value : null;
        } catch (e) {
            return null;
        }
    }

    function decodeActionResponse(status, text) {
        if (!Number.isInteger(status) || status < 100 || status > 599) {
            throw actionError('invalidResponse');
        }
        const json = parseJsonObject(text);
        if (status < 200 || status > 299) {
            const code = json && json.version === 1 ? json.code : undefined;
            if (
                typeof code === 'string' &&
                hasOwn(ACTION_FAILURE_STATUS, code) &&
                ACTION_FAILURE_STATUS[code] === status
            ) {
                throw actionError('action', { code, status });
            }
            throw actionError('http', { status });
        }
        if (!json || json.version !== 1) throw actionError('invalidResponse');
        return json;
    }

    /**
     * send() resolves to the decoded 2xx body or rejects with a MeldPaymentActionError whose `kind`
     * is invalidRequest, invalidResponse, transport, http (`status`), action (`code`) or closed.
     * Nothing is retried here; a caller may retry `transport` with the identical fields and key.
     */
    function createActionClient(descriptor) {
        const bearer = actionBearers.get(descriptor);
        if (!bearer) throw actionError('invalidDescriptor');
        const transport = actionTransportFor(descriptor);
        const pending = new Set();
        let closed = false;

        async function send(operation, fields, key) {
            const values = fields === undefined ? {} : fields;
            if (closed) throw actionError('closed');
            const required = descriptor.operations[operation];
            if (
                typeof required !== 'boolean' ||
                !isPlainObject(values) ||
                hasOwn(values, 'version') ||
                hasOwn(values, 'operation') ||
                (required ? !(typeof key === 'string' && ACTION_KEY.test(key)) : key != null)
            ) {
                throw actionError('invalidRequest');
            }
            let body;
            try {
                body = JSON.stringify(Object.assign({ version: 1, operation }, values));
            } catch (e) {
                throw actionError('invalidRequest');
            }
            if (utf8Length(body) > ACTION_BODY_LIMIT) throw actionError('invalidRequest');
            const headers = {
                'Content-Type': 'application/json',
                Authorization: 'Bearer ' + bearer,
            };
            if (required) headers['X-Idempotency-Key'] = key;
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), ACTION_TIMEOUT_MS);
            pending.add(controller);
            let result;
            try {
                result = await transport.run({
                    url: transport.url,
                    endpoint: descriptor.endpoint,
                    method: 'POST',
                    headers,
                    body,
                    signal: controller.signal,
                });
            } catch (e) {
                throw actionError(closed ? 'closed' : 'transport');
            } finally {
                clearTimeout(timer);
                pending.delete(controller);
            }
            if (closed) throw actionError('closed');
            return decodeActionResponse(result.status, result.body);
        }

        return Object.freeze({
            send,
            close() {
                closed = true;
                pending.forEach((controller) => controller.abort());
                pending.clear();
            },
            toString: () => '[MeldPaymentActionClient REDACTED]',
        });
    }

    // ------------------------------------------------------ attempt journal
    // What a payment-actions adapter keeps across a reload and between tabs, a port of iOS
    // WalletAttemptStore. It holds a mutation key and a fence, never the bearer, a token or
    // customer data. The server stays authoritative; this stops one browser paying an order twice.

    const ATTEMPT_PREFIX = 'meld.attempt.v1:';
    const attemptMemory = new Map();

    function webCrypto() {
        if (global.crypto) return global.crypto;
        return typeof crypto !== 'undefined' ? crypto : undefined;
    }

    /** A fresh idempotency key. */
    function uuid() {
        const source = webCrypto();
        if (source && typeof source.randomUUID === 'function') return source.randomUUID();
        throw actionError('unavailable');
    }

    /** The storage and lock name for an order's actions, or null without SubtleCrypto. */
    async function attemptName(descriptor) {
        const source = webCrypto();
        let subtle = source && source.subtle;
        if (!subtle && typeof crypto !== 'undefined') subtle = crypto.subtle;
        if (!subtle) return null;
        try {
            const bytes = new TextEncoder().encode(descriptor.identity);
            const digest = await subtle.digest('SHA-256', bytes);
            const hex = Array.from(new Uint8Array(digest), (byte) =>
                byte.toString(16).padStart(2, '0'),
            ).join('');
            return ATTEMPT_PREFIX + hex;
        } catch (e) {
            return null;
        }
    }

    /** localStorage under `name`, else memory for the page. An unreadable record throws `storage`. */
    function attemptJournal(descriptor, name) {
        const identity = descriptor.identity;
        let storage = null;
        if (name) {
            try {
                storage = global.localStorage;
                storage.getItem(name);
            } catch (e) {
                storage = null;
            }
        }
        function stored() {
            if (!storage) return null;
            let raw;
            try {
                raw = storage.getItem(name);
            } catch (e) {
                storage = null;
                return null;
            }
            if (raw === null) return null;
            const value = parseJsonObject(raw);
            if (
                !value ||
                typeof value.submissionKey !== 'string' ||
                !ACTION_KEY.test(value.submissionKey) ||
                typeof value.submissionStarted !== 'boolean'
            ) {
                throw actionError('storage');
            }
            return value;
        }
        function record() {
            const durable = stored();
            const remembered = attemptMemory.get(identity);
            return {
                submissionKey:
                    (durable && durable.submissionKey) ||
                    (remembered && remembered.submissionKey) ||
                    uuid(),
                submissionStarted: !!(
                    (durable && durable.submissionStarted) ||
                    (remembered && remembered.submissionStarted)
                ),
            };
        }
        function write(value) {
            attemptMemory.set(identity, value);
            if (!storage) return;
            try {
                storage.setItem(name, JSON.stringify(value));
            } catch (e) {
                storage = null;
            }
        }
        return {
            record,
            claimSubmission() {
                const value = record();
                if (value.submissionStarted) throw actionError('alreadyAttempted');
                value.submissionStarted = true;
                write(value);
                return value.submissionKey;
            },
            observeSubmission() {
                const value = record();
                value.submissionStarted = true;
                write(value);
            },
        };
    }

    /**
     * Stops two tabs driving one order, where Web Locks exist. Waits up to `waitMs` rather than
     * failing at once: a lock frees asynchronously, so a remount of the same order would otherwise
     * find it held. Resolves to a release, or null when another tab keeps the order.
     */
    function acquireOrder(name, waitMs) {
        const none = () => {};
        const locks = global.navigator && global.navigator.locks;
        if (!name || !locks || typeof locks.request !== 'function') return Promise.resolve(none);
        return new Promise((resolve) => {
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), waitMs);
            let unlock;
            const held = new Promise((done) => {
                unlock = done;
            });
            locks
                .request(name, { signal: controller.signal }, () => {
                    clearTimeout(timer);
                    resolve(unlock);
                    return held;
                })
                .catch((e) => {
                    clearTimeout(timer);
                    resolve(e && e.name === 'AbortError' ? null : none);
                });
        });
    }

    // ---------------------------------------------------------------- mercuryo

    /** snake_case URL params -> camelCase run() params (widget_id -> widgetId, …). */
    function camelCase(key) {
        return key.replace(/_([a-z])/g, (_, c) => c.toUpperCase());
    }

    /**
     * Reconstructs mercuryoWidget.run() params from the signed serviceProviderWidgetUrl
     * — the CardOrder carries a single URL and the SDK owns the URL->params mapping.
     * The signature covers the order's identity fields, so every param is passed
     * through untouched apart from the key casing.
     */
    function widgetUrlToRunParams(serviceProviderWidgetUrl) {
        const url = new URL(serviceProviderWidgetUrl);
        const params = {};
        url.searchParams.forEach((value, key) => {
            if (value === 'true' || value === 'false') {
                params[camelCase(key)] = value === 'true';
            } else {
                params[camelCase(key)] = value;
            }
        });
        return { params, host: url.host };
    }

    // Mercuryo's status vocabulary -> the SDK's agnostic status set. Interim/unknown
    // codes (new, pending, processing, …) collapse to 'pending'. The provider-specific
    // mapping lives in the adapter so the public onStatusChange payload stays neutral.
    const MERCURYO_STATUS = {
        paid: 'completed',
        completed: 'completed',
        order_completed: 'completed',
        succeeded: 'completed',
        success: 'completed',
        failed: 'failed',
        order_failed: 'failed',
        failed_exchange: 'failed',
        descriptor_failed: 'failed',
        rejected: 'failed',
        cancelled: 'cancelled',
        canceled: 'cancelled',
    };

    function normalizeMercuryoStatus(code) {
        return MERCURYO_STATUS[code] || 'pending';
    }

    /**
     * Mercuryo card — embedded iframe. Loads embed.2.1.js, runs mercuryoWidget.run()
     * into the host element, and maps Mercuryo client events onto the Meld model:
     *
     *   onReady           -> onReady   (synthesized if Mercuryo's own never fires)
     *   onPaymentFinished -> onPaymentSubmitted (UX HINT — user finished the form, NOT settlement)
     *   onStatusChange    -> onStatusChange with a normalized status; terminal 'failed'
     *                        additionally -> onError, terminal 'cancelled' -> onCancel
     *
     * onCancel fires on Mercuryo's 'cancelled' status (Mercuryo has no separate cancel
     * callback). Tearing the widget down via handle.unmount() does NOT emit onCancel — it is
     * an integrator-initiated teardown, not a user cancellation.
     */
    function mountMercuryoCard(order, details, hostElement, handlers) {
        if (!isRegisteredWidgetUrl('MERCURYO', details.serviceProviderWidgetUrl)) {
            throw new Error('Invalid widget origin for declared presentation.');
        }
        const { params, host } = widgetUrlToRunParams(details.serviceProviderWidgetUrl);
        const environment = inferEnvironment('MERCURYO', host);
        const hosts = PROVIDER_HOSTS.MERCURYO[environment];

        // The order's signed URL is authoritative for the environment, but requiredCsp() keys
        // off config.environment. If they disagree, the integrator most likely built their CSP
        // for the wrong environment, and the provider iframe/script will be blocked by it — a
        // failure that's hard to diagnose from the CSP error alone. Warn with the fix.
        const configuredEnv = providerEnvironment();
        if (environment !== configuredEnv) {
            console.warn(
                "[meld-sdk] order is '" +
                    environment +
                    "' but Meld.configure() said '" +
                    configuredEnv +
                    "'. requiredCsp() was generated for '" +
                    configuredEnv +
                    "', so this order's iframe/script may be blocked by your CSP. " +
                    "Call Meld.configure({ environment: '" +
                    environment +
                    "' }) before requiredCsp() to match the order.",
            );
        }

        // Defensive against a re-used/dirty container (e.g. a double mount() without an
        // intervening unmount, or a React strict-mode remount): start from an empty host
        // so we never stack two provider iframes in the same element.
        clearChildren(hostElement);

        let unmounted = false;
        const timers = []; // ready-synthesis fallbacks; cleared on unmount
        const fireReady = readySynthesizer(order, handlers, () => unmounted);

        loadScriptOnce(hosts.scriptSrc)
            .then(() => {
                if (unmounted) {
                    return;
                }
                if (!global.mercuryoWidget || typeof global.mercuryoWidget.run !== 'function') {
                    throw new Error('mercuryoWidget.run is not available after script load');
                }
                global.mercuryoWidget.run(
                    Object.assign({}, params, {
                        host: hostElement,
                        onReady: fireReady,
                        onLoad: () => {
                            // Widget began loading; first-paint fallback for providers/versions
                            // where onReady never fires.
                            timers.push(setTimeout(fireReady, 2000));
                        },
                        onPaymentFinished: () =>
                            // ⚠ UX hint only — NOT settlement. Settlement truth is the Meld
                            // webhook to the integrator's backend.
                            emit(handlers, 'onPaymentSubmitted', { orderId: order.id }),
                        // Payload per Mercuryo docs: { status, merchant_transaction_id, amount,
                        // currency, network, fiat_amount, fiat_currency, payment_method }.
                        onStatusChange: (status) => {
                            const code = status && (status.status || status);
                            const normalized = normalizeMercuryoStatus(code);
                            // Primary relay: a normalized status every integrator can code
                            // against. status === 'completed' is the provider's "order
                            // complete" — still a UX signal, NOT Meld settlement.
                            emit(handlers, 'onStatusChange', {
                                orderId: order.id,
                                status: normalized, // 'pending' | 'completed' | 'failed' | 'cancelled'
                                providerStatus: code, // raw Mercuryo code, for logging
                                raw: status, // full provider payload (amounts, currency, …)
                            });
                            // Terminal states also fire the dedicated lifecycle event so
                            // integrators handling only onError/onCancel still react.
                            if (normalized === 'failed') {
                                emit(handlers, 'onError', {
                                    orderId: order.id,
                                    code: String(code),
                                    message: 'Mercuryo reported terminal status: ' + code,
                                    recoverable: false,
                                });
                            } else if (normalized === 'cancelled') {
                                emit(handlers, 'onCancel', { orderId: order.id });
                            }
                        },
                    }),
                );
                // Belt-and-suspenders ready synthesis if neither callback arrives.
                timers.push(setTimeout(fireReady, 8000));
            })
            .catch((e) =>
                emit(handlers, 'onError', {
                    orderId: order.id,
                    code: ERROR_CODES.PROVIDER_LOAD_FAILED,
                    message: e.message,
                    // Probe verdict (server-responded vs request-blocked) when available.
                    detail: e.detail,
                    recoverable: true,
                }),
            );

        return {
            mode: 'embedded',
            unmount() {
                unmounted = true;
                timers.forEach(clearTimeout); // drop pending ready-synthesis timers
                // embed.2.1.js has no documented destroy() — removing the container's
                // children removes the provider iframe. The provider script itself stays
                // cached for the next mount.
                clearChildren(hostElement);
            },
        };
    }

    // ------------------------------------------------------------------ uphold
    // Uphold card — a TWO-STEP embedded flow (mirrors the iOS/Android UpholdCardAdapter):
    // Uphold has no combined "card + quote" widget, so the card must be CAPTURED before a
    // purchase quote exists. The SDK still mounts once:
    //   1. Mount the capture (select-for-deposit) widget from the order's session.
    //   2. On its `complete`, pull the captured card id and POST it to the order's
    //      authorize-session endpoint (continuation-token bearer) to get an authorize order.
    //   3. Mount the returned authorize widget; its `complete` -> onPaymentSubmitted.
    // Both steps run Uphold's vendored web SDK (PaymentWidget) which builds its own iframe
    // against the widget host. onReady is deduped across the two mounts (once per mount()).

    /** True when the order's widget URL host is a registered Uphold widget origin. */
    function isUpholdHost(widgetUrl) {
        return isRegisteredWidgetUrl('UPHOLD', widgetUrl);
    }

    /**
     * Pull the captured card id out of a PaymentWidget `complete` event. The widget
     * dispatches a CustomEvent whose `.detail` is the raw widget payload; the id lives at
     * detail.value.selection.id. Also accepts a bare value object (defensive).
     */
    function extractCapturedCardId(e) {
        const detail = e && e.detail !== undefined ? e.detail : e;
        const value = detail && detail.value !== undefined ? detail.value : detail;
        return (value && value.selection && value.selection.id) || null;
    }

    /**
     * Step 2 -> 3 bridge: exchange the captured card id for an authorize order by POSTing
     * to the order's authorize-session endpoint. The continuation token (minted by the
     * backend, carried on the order) is the bearer — no integrator credentials. Returns the
     * authorize order (its paymentMethodResponseDetails carries the authorize widget session).
     */
    function createAuthorizeSession(authorizeSessionUrl, continuationToken, cardId) {
        if (!authorizeSessionUrl) {
            return Promise.reject(new Error('Uphold order is missing authorizeSessionUrl'));
        }
        const headers = { 'Content-Type': 'application/json' };
        if (continuationToken) {
            headers.Authorization = 'Bearer ' + continuationToken;
        }
        return fetch(authorizeSessionUrl, {
            method: 'POST',
            headers,
            body: JSON.stringify({ cardId }),
        }).then((res) => {
            if (!res || !res.ok) {
                const status = res && res.status;
                throw new Error(
                    'authorize-session request failed' + (status ? ' (HTTP ' + status + ')' : ''),
                );
            }
            return res.json();
        });
    }

    // Preselect the Uphold widget payment method from the Meld order's paymentMethodType so the user
    // skips Uphold's "Select a payment method" screen. Card-family types map to Uphold's `card`;
    // anything we can't confidently map falls back to the full picker (card + crypto).
    function upholdPaymentMethods(paymentMethodType) {
        switch ((paymentMethodType || '').toUpperCase()) {
            case 'CREDIT_DEBIT_CARD':
            case 'CREDIT_CARD':
            case 'DEBIT_CARD':
            case 'CARD':
                return [{ type: 'card' }];
            default:
                return [{ type: 'card' }, { type: 'crypto' }];
        }
    }

    function mountUpholdCard(order, details, hostElement, handlers) {
        if (!isUpholdHost(details.serviceProviderWidgetUrl)) {
            throw new Error('Invalid widget origin for declared presentation.');
        }
        let captureHost = '';
        try {
            captureHost = new URL(details.serviceProviderWidgetUrl).host;
        } catch (e) {
            /* left blank -> inferEnvironment falls back to configured env */
        }
        const environment = inferEnvironment('UPHOLD', captureHost);
        const hosts = PROVIDER_HOSTS.UPHOLD[environment];

        const configuredEnv = providerEnvironment();
        if (environment !== configuredEnv) {
            console.warn(
                "[meld-sdk] Uphold order is '" +
                    environment +
                    "' but Meld.configure() said '" +
                    configuredEnv +
                    "'. Call Meld.configure({ environment: '" +
                    environment +
                    "' }) so requiredCsp() matches this order's iframe host.",
            );
        }

        clearChildren(hostElement);

        let unmounted = false;
        let currentWidget = null; // active PaymentWidget, for teardown
        let advancing = false; // capture 'complete' can fire more than once — advance to authorize only once
        const timers = [];
        const fireReady = readySynthesizer(order, handlers, () => unmounted); // once across both widgets

        function teardownCurrent() {
            if (currentWidget && typeof currentWidget.unmount === 'function') {
                try {
                    currentWidget.unmount();
                } catch (e) {
                    /* provider teardown must not throw into the SDK */
                }
            }
            currentWidget = null;
        }

        // Build a PaymentWidget for a session and wire its events. onComplete is step-specific.
        // `label` ('capture'|'authorize') tags the DIAGNOSTIC logs so we can see, in the browser console,
        // exactly which Uphold widget events fire — in particular whether the AUTHORIZE widget ever fires
        // `complete` once its transaction goes terminal (the "Processing your order" spinner is the Uphold
        // widget's own; if it hangs while Uphold shows the tx completed, either `complete` never fired here
        // or the host isn't transitioning off `onPaymentSubmitted`).
        // [diagnostic logging — remove once the spinner-hang is understood]
        function mountWidget(session, onComplete, label) {
            const PaymentWidget = global.MeldUpholdWidget && global.MeldUpholdWidget.PaymentWidget;
            if (!PaymentWidget) {
                throw new Error(
                    'Uphold widget SDK (MeldUpholdWidget.PaymentWidget) unavailable after bundle load',
                );
            }
            const widget = new PaymentWidget(session, {
                paymentMethods: upholdPaymentMethods(order.paymentMethodType),
                theme: { appearance: 'light' },
            });
            widget.on('ready', () => {
                fireReady();
            });
            widget.on('complete', (e) => {
                onComplete(e);
            });
            // Capture forwards no cancel; authorize does.
            //
            // Uphold's capture widget posts a bare `cancel` whenever its own card dialog closes —
            // observed after adding a card and after deleting one, neither of which is the customer
            // abandoning the purchase. Forwarding it ended the Meld flow and tore the host's checkout
            // down mid-card-management. The payload carries nothing to tell that apart from a real
            // abandonment, so the distinction has to be positional: during capture the customer is
            // managing cards and the surface stays up. A genuine exit is the host's own chrome to
            // offer, which it already does.
            //
            // Authorize is different — there, closing the widget really is declining to pay.
            if (label === 'authorize') {
                widget.on('cancel', () => {
                    emit(handlers, 'onCancel', { orderId: order.id });
                });
            }
            widget.on('error', (e) => {
                const err = e && e.detail && e.detail.error;
                emit(handlers, 'onError', {
                    orderId: order.id,
                    code: (err && err.code) || 'uphold_widget_error',
                    message: (err && err.message) || 'Uphold widget reported an error',
                    detail: e && e.detail,
                    recoverable: false,
                });
            });
            widget.mountIframe(hostElement);
            currentWidget = widget;
            return widget;
        }

        // Step 1: capture widget. Its `complete` is NOT settlement — it yields the card id.
        function mountCapture() {
            mountWidget(
                {
                    url: details.serviceProviderWidgetUrl,
                    token: details.sdkSessionToken,
                    flow: details.sdkSessionFlow,
                },
                (e) => {
                    const cardId = extractCapturedCardId(e);
                    if (!cardId) {
                        emit(handlers, 'onError', {
                            orderId: order.id,
                            code: 'authorize_session_invalid',
                            message: 'Uphold capture completed without a card id',
                            recoverable: false,
                        });
                        return;
                    }
                    if (advancing) {
                        return; // a duplicate capture 'complete' — don't fire a second authorize-session POST
                    }
                    advancing = true;
                    advanceToAuthorize(cardId);
                },
                'capture',
            );
        }

        // Steps 2 -> 3: exchange card id for the authorize order, then mount its widget.
        function advanceToAuthorize(cardId) {
            createAuthorizeSession(details.authorizeSessionUrl, details.continuationToken, cardId)
                .then((authorizeOrder) => {
                    if (unmounted) {
                        return;
                    }
                    const ad =
                        (authorizeOrder && authorizeOrder.paymentMethodResponseDetails) || {};
                    teardownCurrent();
                    clearChildren(hostElement);
                    mountWidget(
                        {
                            url: ad.serviceProviderWidgetUrl,
                            token: ad.sdkSessionToken,
                            flow: ad.sdkSessionFlow,
                            // Uphold's authorize flow requires the quote id as session data.quoteId — the
                            // token alone isn't enough (widget throws "Missing 'quoteId' parameter in 'data'").
                            // Backend supplies it on the authorize order as sdkSessionData: { quoteId }.
                            data: ad.sdkSessionData || undefined,
                        },
                        // Authorize `complete` IS the user finishing the purchase form — a UX
                        // hint, NOT settlement (settlement truth is the Meld webhook).
                        () => {
                            emit(handlers, 'onPaymentSubmitted', { orderId: order.id });
                        },
                        'authorize',
                    );
                })
                .catch((e) => {
                    advancing = false; // allow a retry after a failed authorize-session exchange
                    emit(handlers, 'onError', {
                        orderId: order.id,
                        code: 'authorize_session_failed',
                        message: e.message,
                        recoverable: true,
                    });
                });
        }

        // The Uphold widget is inlined into this SDK (globalThis.MeldUpholdWidget, installed at
        // load) — no runtime script fetch. Mount synchronously; mountWidget throws a clear error
        // if the vendored widget is somehow absent.
        try {
            if (!unmounted) {
                mountCapture();
                timers.push(setTimeout(fireReady, 8000)); // belt-and-suspenders ready synthesis
            }
        } catch (e) {
            emit(handlers, 'onError', {
                orderId: order.id,
                code: ERROR_CODES.PROVIDER_LOAD_FAILED,
                message: e.message,
                detail: e.detail,
                recoverable: true,
            });
        }

        return {
            mode: 'embedded',
            unmount() {
                unmounted = true;
                timers.forEach(clearTimeout);
                teardownCurrent();
                clearChildren(hostElement);
            },
        };
    }

    // ------------------------------------------------------------------- banxa

    /**
     * Banxa card. The only web provider whose SDK is used as its vendor intends: Banxa's
     * <banxa-primer-checkout> takes a client token and a method list, so no Banxa credential ever
     * reaches the browser and the order stays Meld's. Card and Apple Pay are the same component and
     * the same token — only `payment-methods` differs.
     *
     * Apple Pay works here and only here. Apple Pay on the Web refuses to run unless the page origin
     * is a domain registered with Apple for Apple Pay, and on the web that origin is the integrator's
     * own page — theirs to register. The native SDKs load this component inside a WebView whose origin
     * is Primer's, which is nobody's to register, so they cannot present the sheet this way.
     *
     * Distinct from every other adapter here in that there is NO provider URL to load — the surface
     * is built from the token alone. There is deliberately no fallback to serviceProviderWidgetUrl:
     * for Banxa that URL is its full hosted checkout (sign-in, email OTP, KYC, method picker), a
     * different product rather than a lesser rendering of this one.
     *
     * Events are Primer's, re-dispatched by the component under a `banxa:` prefix.
     */
    /**
     * Loads Banxa's checkout module.
     *
     * Dynamic import rather than loadScriptOnce: the package is an ES module, and jsDelivr's /+esm
     * endpoint is what resolves its bare `@primer-io/primer-js` import.
     *
     * Held in a variable so tests can substitute a module object. Everything that makes this adapter
     * different from the others — registering the custom element, creating it, naming the events it
     * relays, assigning the token last — happens after the module resolves, so without a seam none of
     * it is reachable in a test and a renamed export or event would ship green. The native SDKs take
     * an injected presenter for the same reason.
     */
    let loadBanxaModule = function (src) {
        return import(/* webpackIgnore: true */ src);
    };

    function mountBanxaCheckout(order, details, hostElement, handlers) {
        const hosts = PROVIDER_HOSTS.BANXA[providerEnvironment()];
        const clientToken = details.sdkSessionToken;
        // The component's own vocabulary. Both surfaces are the same component and the same token —
        // this attribute is the only thing that differs.
        const paymentMethods =
            order.paymentMethodType === 'APPLE_PAY' ? 'APPLE_PAY' : 'PAYMENT_CARD';

        // Before the token check, not after: the SDK's contract is that mounting empties the host,
        // and a reused container that still shows the previous surface while onError fires reads as
        // "the old widget is still live" to anyone looking at the page.
        clearChildren(hostElement);

        if (!clientToken) {
            emit(handlers, 'onError', {
                orderId: order.id,
                code: 'missing_client_token',
                message:
                    'Banxa order is missing sdkSessionToken, the Primer client token the checkout ' +
                    'mounts from. The backend did not receive one from Banxa for this order.',
                recoverable: false,
            });
            return { mode: 'embedded', unmount: function () {} };
        }

        let unmounted = false;
        let element = null;

        loadBanxaModule(hosts.moduleSrc)
            .then(function (sdk) {
                if (unmounted) {
                    return;
                }
                if (!sdk || typeof sdk.registerBanxaPrimerCheckout !== 'function') {
                    throw new Error(
                        'registerBanxaPrimerCheckout is not available after module load',
                    );
                }
                sdk.registerBanxaPrimerCheckout();

                element = document.createElement('banxa-primer-checkout');
                // Set before the token: the component reads its method list when the token setter
                // kicks off the session, so setting it after would start a card session.
                element.setAttribute('payment-methods', paymentMethods);

                // 'ready' is Primer's, not a page-load proxy — unlike the WebView adapters there is
                // no navigation event to fall back on, so no ready synthesis here.
                element.addEventListener('banxa:ready', function () {
                    emit(handlers, 'onReady', { orderId: order.id });
                });
                element.addEventListener('banxa:payment-success', function () {
                    // UX hint only — NOT settlement. Settlement truth is the Meld webhook to the
                    // integrator's backend.
                    emit(handlers, 'onPaymentSubmitted', { orderId: order.id });
                });
                element.addEventListener('banxa:payment-cancel', function () {
                    emit(handlers, 'onCancel', { orderId: order.id });
                });
                element.addEventListener('banxa:payment-failure', function (event) {
                    const detail = (event && event.detail) || {};
                    emit(handlers, 'onError', {
                        orderId: order.id,
                        code: detail.errorCode || 'payment_failure',
                        message: detail.errorMessage || 'Banxa checkout reported a payment failure',
                        recoverable: false,
                    });
                });
                // banxa:card-error is deliberately NOT relayed: it is inline field validation that
                // fires while the user types, and surfacing it would spam onError.

                hostElement.appendChild(element);
                // Set as a property, but be clear about what that buys: the component's setter
                // reflects clientToken straight to the `client-token` attribute, so the Primer client
                // token IS in the integrator's DOM for the life of the surface, readable by any
                // third-party tag on the page. It is a short-lived, order-scoped session token, not a
                // credential, but integrators should know it is exposed there.
                element.clientToken = clientToken;
            })
            .catch(function (e) {
                if (unmounted) {
                    return;
                }
                emit(handlers, 'onError', {
                    orderId: order.id,
                    code: ERROR_CODES.PROVIDER_LOAD_FAILED,
                    message:
                        'Banxa checkout SDK failed to load: ' + (e && e.message ? e.message : e),
                    // Recoverable: nothing was charged and nothing about the order is wrong — the
                    // module did not arrive. A CDN blip or a flaky connection is exactly the case
                    // where mounting the same order again works.
                    recoverable: true,
                });
            });

        return {
            mode: 'embedded',
            unmount: function () {
                unmounted = true;
                if (element && element.remove) {
                    element.remove();
                }
                element = null;
                clearChildren(hostElement);
            },
        };
    }

    // ------------------------------------------------------------- coinbase pay
    // Coinbase guest-checkout Apple Pay, from the order's hosted payment link. The iOS SDK loads the
    // link as a hidden top-level page and clicks its button; a cross-origin frame cannot be clicked,
    // so here the frame is visible and the customer presses the button. Event mapping follows iOS
    // HostedLinkApplePayAdapter.

    const COINBASE_LOAD_TIMEOUT_MS = 20000;
    // Off until the deployed API echoes payload.browserOrigin (payment-domain #3725). Until then
    // coinbaseAdmissionError declines every order after Coinbase has created it, so no row is offered.
    let coinbaseOffered = false;

    /** Why this page cannot embed the order's link, or null. Reasons carry no order data. */
    function coinbaseAdmissionError(order, details) {
        const location = global.location;
        if (!location || typeof location.origin !== 'string') return 'there is no browser page';
        if (hasOwn(details, 'presentation') && details.presentation !== 'PROVIDER_HOSTED') {
            return 'the order is not a provider-hosted Apple Pay link';
        }
        if (
            typeof details.paymentLinkUrl !== 'string' ||
            !isRegisteredWidgetUrl('COINBASEPAY', details.paymentLinkUrl)
        ) {
            return 'the payment link is not on a registered Coinbase host';
        }
        const localSandbox =
            location.protocol === 'http:' &&
            providerEnvironment() === 'sandbox' &&
            ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);
        if (location.protocol !== 'https:' && !localSandbox) {
            return 'the page is not served over HTTPS';
        }
        // Coinbase only renders a link inside a frame on the domain it was created for.
        if (!order.payload || order.payload.browserOrigin !== location.origin) {
            return 'the order was not created for this page origin';
        }
        return null;
    }

    function coinbaseErrorCode(eventName, providerCode) {
        if (
            providerCode === 'ERROR_CODE_GUEST_APPLE_PAY_NOT_SUPPORTED' ||
            providerCode === 'ERROR_CODE_GUEST_APPLE_PAY_NOT_SETUP'
        ) {
            return ERROR_CODES.PAYMENT_METHOD_UNAVAILABLE;
        }
        if (providerCode === 'ERROR_CODE_INIT') return ERROR_CODES.ORDER_STATE_CHANGED;
        if (eventName === 'onramp_api.commit_error') return ERROR_CODES.PAYMENT_REJECTED;
        if (eventName === 'onramp_api.polling_error') return ERROR_CODES.PAYMENT_OUTCOME_UNKNOWN;
        return ERROR_CODES.PRESENTATION_FAILED;
    }

    /** `{ eventName, data: { errorCode } }`, as an object or a JSON string; anything else is null. */
    function parseCoinbaseMessage(data) {
        let message = data;
        if (typeof message === 'string') {
            if (message.length > 16384) return null;
            try {
                message = JSON.parse(message);
            } catch (e) {
                return null;
            }
        }
        if (!isPlainObject(message)) return null;
        const eventName = message.eventName;
        if (typeof eventName !== 'string' || eventName.length > 100) return null;
        const payload = message.data;
        if (payload != null && !isPlainObject(payload)) return null;
        const errorCode = payload ? payload.errorCode : undefined;
        if (errorCode != null && (typeof errorCode !== 'string' || errorCode.length > 128)) {
            return null;
        }
        return { eventName, errorCode: errorCode || undefined };
    }

    function mountCoinbaseApplePay(order, details, hostElement, handlers) {
        if (coinbaseAdmissionError(order, details)) {
            throw new Error('Invalid widget origin for declared presentation.');
        }
        const orderId = order.id;
        const link = details.paymentLinkUrl;
        const origin = new URL(link).origin;
        clearChildren(hostElement);

        const iframe = document.createElement('iframe');
        iframe.title = 'Apple Pay checkout';
        iframe.setAttribute('sandbox', 'allow-scripts allow-same-origin');
        iframe.setAttribute('referrerpolicy', 'no-referrer');
        iframe.setAttribute('allow', 'payment');
        iframe.style.width = '100%';
        iframe.style.height = '100%';
        iframe.style.border = '0';

        let phase = 'loading'; // loading -> ready -> submitted -> ended
        let loadTimer = null;

        function stopLoadTimer() {
            clearTimeout(loadTimer);
            loadTimer = null;
        }

        function end() {
            phase = 'ended';
            stopLoadTimer();
        }

        function close() {
            end();
            global.removeEventListener('message', onMessage);
            iframe.remove();
        }

        function fail(code, detail, message) {
            close();
            emit(handlers, 'onError', meldError(orderId, code, detail, message));
        }

        function ready() {
            if (phase !== 'loading') return;
            phase = 'ready';
            stopLoadTimer();
            emit(handlers, 'onReady', { orderId });
        }

        function receive(eventName, errorCode) {
            switch (eventName) {
                case 'onramp_api.load_success':
                    ready();
                    return;
                case 'onramp_api.commit_success':
                case 'onramp_api.polling_start':
                    if (phase === 'submitted') return;
                    phase = 'submitted';
                    stopLoadTimer();
                    emit(handlers, 'onStatusChange', {
                        orderId,
                        status: 'pending',
                        providerStatus: eventName,
                    });
                    emit(handlers, 'onPaymentSubmitted', { orderId });
                    return;
                case 'onramp_api.polling_success':
                    end();
                    emit(handlers, 'onStatusChange', {
                        orderId,
                        status: 'completed',
                        providerStatus: eventName,
                    });
                    return;
                case 'onramp_api.cancel':
                case 'onramp_api.polling_cancel':
                    if (phase === 'submitted') {
                        fail(ERROR_CODES.PAYMENT_OUTCOME_UNKNOWN, eventName);
                        return;
                    }
                    close();
                    emit(handlers, 'onCancel', { orderId });
                    return;
                case 'onramp_api.load_error':
                    // Outside Safari the page reports this and shows its QR-code fallback, which
                    // still pays the order.
                    if (errorCode === 'ERROR_CODE_GUEST_APPLE_PAY_NOT_SUPPORTED') {
                        ready();
                        return;
                    }
                // falls through
                case 'onramp_api.commit_error':
                case 'onramp_api.polling_error':
                case 'onramp_api.validate_merchant_error':
                case 'onramp_api.error': {
                    const code =
                        phase === 'submitted'
                            ? ERROR_CODES.PAYMENT_OUTCOME_UNKNOWN
                            : coinbaseErrorCode(eventName, errorCode);
                    fail(code, errorCode ? eventName + ':' + errorCode : eventName);
                    return;
                }
                default:
                    return;
            }
        }

        function onMessage(event) {
            if (
                phase === 'ended' ||
                event.origin !== origin ||
                event.source !== iframe.contentWindow
            ) {
                return;
            }
            const message = parseCoinbaseMessage(event.data);
            if (message) receive(message.eventName, message.errorCode);
        }

        global.addEventListener('message', onMessage);
        loadTimer = setTimeout(() => {
            if (phase === 'loading') {
                fail(
                    ERROR_CODES.PRESENTATION_FAILED,
                    'load_timeout',
                    "The provider's page did not load.",
                );
            }
        }, COINBASE_LOAD_TIMEOUT_MS);
        iframe.src = link;
        hostElement.appendChild(iframe);

        return {
            mode: 'embedded',
            unmount() {
                close();
                clearChildren(hostElement);
            },
        };
    }

    // ------------------------------------------------------------------ stripe
    // Stripe embedded components, a port of iOS StripeFlowController onto Stripe's web runtime.
    // The web runtime has no hasLinkAccount, seamless sign-in or verifyKYCInfo, so every sign-in
    // goes through PREPARE_CUSTOMER_AUTHORIZATION, registers only when the server says so, and
    // authenticates with the link auth intent it returns.

    const STRIPE_SCRIPT = 'https://js.stripe.com/crypto-onramp/v1/crypto-onramp.js';
    // The pause between pending verification reads, the wait for an order lock another mount still
    // holds, and the limit on loading Stripe's runtime. Tests shorten them via __setStripeTimings.
    const STRIPE_TIMINGS = Object.freeze({
        pendingPauseMs: 2000,
        lockWaitMs: 3000,
        runtimeTimeoutMs: 30000,
    });
    let stripeTimings = STRIPE_TIMINGS;
    // Off until Stripe enables its web components, a private preview, for a partner account. Until
    // then an order would be created at Stripe and then fail to load, so no Stripe row is offered.
    let stripeOffered = false;
    const STRIPE_LOOPS = 12;
    const STRIPE_PAYMENT_PRESENTATIONS = 3;
    const STRIPE_RUNTIME_METHODS = [
        'registerLinkUser',
        'authenticate',
        'submitKycInfo',
        'verifyDocuments',
        'registerWalletAddress',
        'collectPaymentMethod',
        'performCheckout',
        'destroy',
    ];
    const STRIPE_OPERATIONS = Object.freeze({
        READ_SUBMISSION: false,
        READ_CUSTOMER_STATUS: false,
        READ_LIMITS: false,
        COMPLETE_CUSTOMER_LINK: true,
        PREPARE_CUSTOMER_AUTHORIZATION: true,
        CREATE_PAYMENT_SESSION: true,
        CONFIRM_PAYMENT: true,
        REFRESH_QUOTE: true,
    });
    const STRIPE_STATUSES = new Set([
        'READY',
        'NOT_STARTED',
        'PENDING',
        'AUTHORIZED',
        'VERIFIED',
        'REJECTED',
        'NOT_AVAILABLE',
        'UNKNOWN',
        'REQUIRES_PAYMENT',
        'QUOTE_READY',
        'FULFILLMENT_PROCESSING',
        'FULFILLMENT_COMPLETE',
        'SUCCEEDED',
        'FAILED',
        'SUBMITTED',
        'IN_PROGRESS',
        'EXPIRED',
    ]);
    const STRIPE_STEPS = new Set([
        'NONE',
        'SDK_REGISTER_CUSTOMER',
        'SDK_AUTHORIZE',
        'SDK_REAUTHORIZE',
        'SDK_COLLECT_KYC',
        'SDK_VERIFY_IDENTITY',
        'SDK_REGISTER_WALLET',
        'SDK_COLLECT_PAYMENT_METHOD',
        'CREATE_PAYMENT_SESSION',
        'REFRESH_QUOTE',
        'CONFIRM_PAYMENT',
        'RETRY',
        'COMPLETE',
        'REGION_NOT_SUPPORTED',
        'START_NEW_ORDER',
        'WAIT_FOR_PAYMENT',
        'WAIT_FOR_PROVIDER',
        'UNKNOWN',
    ]);
    const STRIPE_MISSING_FIELDS = new Set([
        'FIRST_NAME',
        'LAST_NAME',
        'DATE_OF_BIRTH',
        'ID_NUMBER',
        'ADDRESS_LINE_1',
        'ADDRESS_CITY',
        'ADDRESS_STATE',
        'ADDRESS_POSTAL_CODE',
        'ADDRESS_COUNTRY',
        'ID_DOCUMENT',
        'SELFIE',
    ]);
    const STRIPE_IDENTITY_FIELDS = [
        'FIRST_NAME',
        'LAST_NAME',
        'DATE_OF_BIRTH',
        'ID_NUMBER',
        'ADDRESS_LINE_1',
        'ADDRESS_CITY',
        'ADDRESS_STATE',
        'ADDRESS_POSTAL_CODE',
        'ADDRESS_COUNTRY',
    ];
    const STRIPE_CUSTOMER_STATES = new Set([
        'VERIFIED/CREATE_PAYMENT_SESSION',
        'VERIFIED/REFRESH_QUOTE',
        'VERIFIED/NONE',
        'NOT_STARTED/SDK_COLLECT_KYC',
        'REJECTED/SDK_COLLECT_KYC',
        'NOT_STARTED/SDK_VERIFY_IDENTITY',
        'REJECTED/SDK_VERIFY_IDENTITY',
        'PENDING/RETRY',
        'NOT_AVAILABLE/REGION_NOT_SUPPORTED',
    ]);
    const STRIPE_CHECKOUT_FOLLOW_UPS = new Set([
        'SDK_COLLECT_KYC',
        'SDK_VERIFY_IDENTITY',
        'SDK_REGISTER_WALLET',
        'REFRESH_QUOTE',
    ]);
    const STRIPE_FORM_FIELDS = {
        name: { label: 'Full name (optional)', autocomplete: 'name' },
        phone: {
            label: 'Mobile number',
            type: 'tel',
            autocomplete: 'tel',
            placeholder: '(415) 555-0123',
        },
        firstName: { label: 'First name', autocomplete: 'given-name' },
        lastName: { label: 'Last name', autocomplete: 'family-name' },
        birthday: {
            label: 'Date of birth (YYYY-MM-DD)',
            autocomplete: 'bday',
            placeholder: '1990-03-15',
        },
        idNumber: {
            label: 'Social Security number',
            type: 'password',
            autocomplete: 'off',
            inputMode: 'numeric',
        },
        line1: { label: 'Street address', autocomplete: 'address-line1' },
        line2: { label: 'Apartment or suite (optional)', autocomplete: 'address-line2' },
        city: { label: 'City', autocomplete: 'address-level2' },
        state: { label: 'State (two letters)', autocomplete: 'address-level1' },
        postalCode: { label: 'ZIP code', autocomplete: 'postal-code', inputMode: 'numeric' },
    };
    const STRIPE_ADDRESS_FORM = ['line1', 'line2', 'city', 'state', 'postalCode'];

    function stripeError(kind) {
        const error = new Error('Stripe checkout stopped: ' + kind);
        error.name = 'MeldStripeError';
        error.kind = kind;
        return error;
    }

    function stripeText(value, limit) {
        return typeof value === 'string' &&
            value.length > 0 &&
            utf8Length(value) <= limit &&
            !/[\p{Cc}\p{Cf}]/u.test(value) &&
            value.trim() === value
            ? value
            : null;
    }

    function stripeMatches(text, pattern) {
        return new RegExp('^(?:' + pattern + ')$').test(text);
    }

    function stripeIdentifier(value, prefix) {
        const text = stripeText(value, 255);
        return text && stripeMatches(text, prefix + '[A-Za-z0-9_]+') ? text : null;
    }

    function stripeAmount(value) {
        return typeof value === 'number' &&
            Number.isFinite(value) &&
            value > 0 &&
            /^[0-9]+(?:\.[0-9]{1,2})?$/.test(String(value))
            ? value
            : null;
    }

    function stripeBirthday(text) {
        if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(text)) return null;
        const [year, month, day] = text.split('-').map(Number);
        const date = new Date(Date.UTC(year, month - 1, day));
        if (
            year < 1900 ||
            date.getUTCFullYear() !== year ||
            date.getUTCMonth() !== month - 1 ||
            date.getUTCDate() !== day ||
            date.getTime() >= Date.now()
        ) {
            return null;
        }
        return { day, month, year };
    }

    /** What the customer typed, in the form Stripe takes. Ten digits are read as a US number. */
    function stripeNormalizedField(field, text) {
        const trimmed = String(text).trim();
        if (field === 'state') return trimmed.toUpperCase();
        if (field === 'idNumber') return trimmed.replace(/[\s-]/g, '');
        if (field !== 'phone') return trimmed;
        const digits = trimmed.replace(/[^0-9]/g, '');
        if (trimmed.startsWith('+')) return '+' + digits;
        if (digits.length === 10) return '+1' + digits;
        if (digits.length === 11 && digits.startsWith('1')) return '+' + digits;
        return trimmed;
    }

    function stripeValidField(field, text) {
        if ((field === 'name' || field === 'line2') && text === '') return true;
        if (!stripeText(text, field === 'email' ? 254 : 255)) return false;
        switch (field) {
            case 'email':
                return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(text);
            case 'phone':
                return /^\+[1-9][0-9]{7,14}$/.test(text);
            case 'birthday':
                return stripeBirthday(text) !== null;
            case 'idNumber':
                return /^[0-9]{9}$/.test(text);
            case 'state':
                return /^[A-Za-z]{2}$/.test(text);
            case 'postalCode':
                return /^[0-9]{5}(?:-[0-9]{4})?$/.test(text);
            default:
                return true;
        }
    }

    /**
     * Customer data Meld already holds. Optional: an unusable field is dropped and asked for, and
     * only an unusable email (the one Meld authorizes Link with) drops the whole prefill.
     */
    function stripePrefill(raw) {
        if (!isPlainObject(raw) || !stripeValidField('email', raw.email)) return null;
        const field = (value, name) =>
            typeof value === 'string' && value !== '' && stripeValidField(name, value)
                ? value
                : null;
        let identity = null;
        if (isPlainObject(raw.identity)) {
            const source = raw.identity;
            const birthday =
                typeof source.dateOfBirth === 'string' ? stripeBirthday(source.dateOfBirth) : null;
            let address = null;
            const a = source.address;
            if (isPlainObject(a) && a.country === 'US') {
                const line2 = hasOwn(a, 'line2') ? field(a.line2, 'line2') : null;
                const parts = {
                    line1: field(a.line1, 'line1'),
                    city: field(a.city, 'city'),
                    state: field(a.state, 'state'),
                    postalCode: field(a.postalCode, 'postalCode'),
                };
                if (
                    parts.line1 &&
                    parts.city &&
                    parts.state &&
                    parts.postalCode &&
                    (!hasOwn(a, 'line2') || line2)
                ) {
                    address = Object.assign(parts, { state: parts.state.toUpperCase(), line2 });
                }
            }
            const firstName = field(source.firstName, 'firstName');
            const lastName = field(source.lastName, 'lastName');
            if (firstName || lastName || birthday || address) {
                identity = { firstName, lastName, birthday, address };
            }
        }
        return Object.freeze({
            email: raw.email,
            phone: field(raw.phone, 'phone'),
            fullName: field(raw.fullName, 'name'),
            identity,
            toString: () => '[MeldStripePrefill REDACTED]',
        });
    }

    /** Validated inputs for the adapter, a port of iOS StripeNativeOrder. */
    function stripeOrder(order) {
        const decline = (reason) => Object.assign(stripeError('invalidOrder'), { reason });
        const presentation = order && order.headlessPresentation;
        const details = order && order.paymentMethodResponseDetails;
        if (
            !isPlainObject(presentation) ||
            presentation.surface !== 'NATIVE_SDK' ||
            presentation.protocol !== 'STRIPE_CRYPTO_ONRAMP' ||
            presentation.version !== 1 ||
            !['APPLE_PAY', 'CREDIT_DEBIT_CARD'].includes(order.paymentMethodType) ||
            !stripeText(order.id, 64) ||
            !isPlainObject(details) ||
            details.sdkBootstrapType !== 'STRIPE_CRYPTO_ONRAMP' ||
            !['REGISTER', 'AUTHORIZE', 'SEAMLESS'].includes(details.sdkFlow) ||
            !Number.isInteger(details.expiresAtEpochSeconds) ||
            details.expiresAtEpochSeconds <= 0
        ) {
            throw decline('it is not a Stripe crypto onramp order');
        }
        const sdkEnvironment = details.sdkEnvironment;
        if (
            !['SANDBOX', 'DEVELOPMENT', 'PRODUCTION'].includes(sdkEnvironment) ||
            ((config.environment || 'sandbox') === 'production') !==
                (sdkEnvironment === 'PRODUCTION')
        ) {
            throw decline('it belongs to another environment');
        }
        const configuration = details.clientConfiguration;
        const publicKey = isPlainObject(configuration)
            ? stripeText(configuration.publicKey, 255)
            : null;
        if (
            !publicKey ||
            !stripeMatches(
                publicKey,
                'pk_' + (sdkEnvironment === 'PRODUCTION' ? 'live' : 'test') + '_[A-Za-z0-9]+',
            ) ||
            // Stripe rejects an unsupported network itself, before any payment.
            !stripeText(configuration.walletNetwork, 64)
        ) {
            throw decline('its Stripe client configuration is not usable');
        }
        const payload = order.payload;
        const walletAddress = isPlainObject(payload)
            ? stripeText(payload.destinationWalletAddress, 255)
            : null;
        const amount = isPlainObject(payload) ? stripeAmount(payload.sourceAmount) : null;
        if (
            !walletAddress ||
            amount === null ||
            payload.sourceCurrencyCode !== 'USD' ||
            payload.countryCode !== 'US'
        ) {
            throw decline('it is not a US dollar purchase in the US');
        }
        if (
            payload.browserOrigin != null &&
            payload.browserOrigin !== (global.location && global.location.origin)
        ) {
            throw decline('it was not created for this page origin');
        }
        const intent = stripeIdentifier(details.providerIntentId, 'lai_');
        if (details.sdkFlow === 'REGISTER' ? details.providerIntentId != null : !intent) {
            throw decline('its authorization intent does not match its flow');
        }
        let actions;
        try {
            actions = paymentActionDescriptor(order);
        } catch (e) {
            throw decline('its payment actions are not valid');
        }
        if (
            Object.keys(STRIPE_OPERATIONS).some(
                (operation) => actions.operations[operation] !== STRIPE_OPERATIONS[operation],
            )
        ) {
            throw decline('its payment actions do not declare the Stripe operations');
        }
        return Object.freeze({
            id: order.id,
            method: order.paymentMethodType,
            flow: details.sdkFlow,
            publicKey,
            walletNetwork: configuration.walletNetwork,
            walletAddress,
            amount,
            actions,
            toString: () => '[MeldStripeOrder REDACTED]',
        });
    }

    function stripeAdmissionError(order) {
        try {
            stripeOrder(order);
            return null;
        } catch (e) {
            return e.reason || 'it is not a Stripe crypto onramp order';
        }
    }

    /** A port of iOS StripeActionResponse. Secrets stay on the frozen object, never in strings. */
    function stripeResponse(value) {
        const invalid = () => stripeError('invalidResponse');
        if (
            !isPlainObject(value) ||
            value.version !== 1 ||
            !STRIPE_STATUSES.has(value.status) ||
            !STRIPE_STEPS.has(value.nextStep)
        ) {
            throw invalid();
        }
        const parsed = {
            status: value.status,
            next: value.nextStep,
            session: null,
            authentication: null,
            intent: null,
            secret: null,
            expiresAt: null,
            prefill: null,
            missingFields: [],
            hasCustomer: false,
            limits: value.limits,
            toString: () => '[MeldStripeResponse REDACTED]',
        };
        if (hasOwn(value, 'sdk')) {
            const sdk = value.sdk;
            if (!isPlainObject(sdk)) throw invalid();
            if (hasOwn(sdk, 'authenticationState')) {
                if (!['BOOTSTRAP', 'RESTORE', 'REAUTHORIZE'].includes(sdk.authenticationState)) {
                    throw invalid();
                }
                parsed.authentication = sdk.authenticationState;
            }
            if (hasOwn(sdk, 'authorizationHandle')) {
                parsed.intent = stripeIdentifier(sdk.authorizationHandle, 'lai_');
                if (!parsed.intent) throw invalid();
            }
            if (hasOwn(sdk, 'sessionHandle')) {
                parsed.session = stripeIdentifier(sdk.sessionHandle, 'cos_');
                if (!parsed.session) throw invalid();
            }
            if (hasOwn(sdk, 'clientSecret')) {
                parsed.secret = stripeText(sdk.clientSecret, 4096);
                if (!parsed.secret) throw invalid();
            }
            if (hasOwn(sdk, 'expiresAt')) {
                parsed.expiresAt =
                    typeof sdk.expiresAt === 'string' &&
                    /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/.test(sdk.expiresAt)
                        ? Date.parse(sdk.expiresAt)
                        : NaN;
                if (!Number.isFinite(parsed.expiresAt)) throw invalid();
            }
            if (hasOwn(sdk, 'prefill')) parsed.prefill = stripePrefill(sdk.prefill);
        }
        if (hasOwn(value, 'customer')) {
            const fields = isPlainObject(value.customer) ? value.customer.missingFields : null;
            if (
                !Array.isArray(fields) ||
                !fields.every((field) => STRIPE_MISSING_FIELDS.has(field)) ||
                new Set(fields).size !== fields.length
            ) {
                throw invalid();
            }
            parsed.missingFields = fields.slice();
            parsed.hasCustomer = true;
        }
        if (value.nextStep === 'SDK_REGISTER_CUSTOMER' && hasOwn(value, 'sdk')) throw invalid();
        return Object.freeze(parsed);
    }

    function stripeCustomerAction(response, requiresDetails) {
        if (
            (requiresDetails && !response.hasCustomer) ||
            response.session ||
            response.secret ||
            response.expiresAt !== null ||
            response.intent ||
            response.authentication ||
            !STRIPE_CUSTOMER_STATES.has(response.status + '/' + response.next)
        ) {
            throw stripeError('invalidResponse');
        }
        return response;
    }

    function stripeAuthorizationIntent(response) {
        if (
            response.status !== 'READY' ||
            response.next !== 'SDK_AUTHORIZE' ||
            response.authentication !== 'REAUTHORIZE' ||
            response.session ||
            response.secret ||
            !response.intent ||
            !(response.expiresAt > Date.now())
        ) {
            throw stripeError('invalidResponse');
        }
        return response.intent;
    }

    function stripeRequiresRegistration(response) {
        if (response.next !== 'SDK_REGISTER_CUSTOMER') return false;
        if (
            response.status !== 'NOT_STARTED' ||
            response.session ||
            response.secret ||
            response.expiresAt !== null ||
            response.intent ||
            response.authentication ||
            response.hasCustomer
        ) {
            throw stripeError('invalidResponse');
        }
        return true;
    }

    function stripeCheckoutSecret(response, session) {
        if (
            response.session !== session ||
            response.intent ||
            response.authentication ||
            !response.secret ||
            (response.expiresAt !== null && !(response.expiresAt > Date.now())) ||
            ![
                'REQUIRES_PAYMENT',
                'QUOTE_READY',
                'FULFILLMENT_PROCESSING',
                'FULFILLMENT_COMPLETE',
                'SUCCEEDED',
            ].includes(response.status) ||
            !['CONFIRM_PAYMENT', 'NONE', 'COMPLETE'].includes(response.next)
        ) {
            throw stripeError('invalidResponse');
        }
        return response.secret;
    }

    function stripeSubmission(response) {
        const invalid = () => stripeError('invalidResponse');
        if (response.secret || response.expiresAt !== null || response.intent) throw invalid();
        const state = response.status + '/' + response.next;
        if (state === 'READY/REFRESH_QUOTE') {
            if (
                !response.session ||
                !response.authentication ||
                response.authentication === 'BOOTSTRAP'
            ) {
                throw invalid();
            }
            return {
                kind: 'resumeSession',
                session: response.session,
                authentication: response.authentication,
            };
        }
        if (state === 'NOT_STARTED/NONE' && !response.session) {
            if (!response.authentication) throw invalid();
            return { kind: 'notStarted', authentication: response.authentication };
        }
        if (response.authentication || response.session) throw invalid();
        const kind = {
            'IN_PROGRESS/WAIT_FOR_PROVIDER': 'inProgress',
            'SUBMITTED/WAIT_FOR_PAYMENT': 'submitted',
            'SUCCEEDED/COMPLETE': 'completed',
            'FAILED/NONE': 'failed',
            'REJECTED/NONE': 'failed',
            'EXPIRED/NONE': 'expired',
            'UNKNOWN/WAIT_FOR_PROVIDER': 'unknown',
        }[state];
        if (!kind) throw invalid();
        return { kind };
    }

    /** The highest card limit in USD, or null when Stripe reported none we can read. */
    function stripeLimitCeiling(limits) {
        if (!isPlainObject(limits) || limits.availability !== 'AVAILABLE') return null;
        if (!Array.isArray(limits.limits)) return null;
        const amounts = limits.limits
            .filter(
                (limit) =>
                    isPlainObject(limit) &&
                    limit.currency === 'USD' &&
                    limit.paymentMethod === 'CREDIT_DEBIT_CARD' &&
                    typeof limit.amount === 'number' &&
                    Number.isFinite(limit.amount),
            )
            .map((limit) => limit.amount);
        return amounts.length ? Math.max(...amounts) : null;
    }

    function stripeKycInfo(input) {
        const info = {};
        if (input.firstName) info.given_name = input.firstName;
        if (input.lastName) info.surname = input.lastName;
        if (input.idNumber) info.id_number = { type: 'us_ssn', value: input.idNumber };
        if (input.birthday) info.date_of_birth = Object.assign({}, input.birthday);
        if (input.address) {
            info.address = {
                line1: input.address.line1,
                city: input.address.city,
                state: input.address.state,
                postal_code: input.address.postalCode,
                country: 'US',
            };
            if (input.address.line2) info.address.line2 = input.address.line2;
        }
        return info;
    }

    // ---- runtime

    /** Stripe's runtime is an ES module that installs one global; a page may have loaded it already. */
    function loadStripeConstructor() {
        const loaded = () => typeof global.loadCryptoOnrampAndInitialize === 'function';
        if (loaded()) return Promise.resolve(global.loadCryptoOnrampAndInitialize);
        return loadScriptOnce(STRIPE_SCRIPT, {
            module: true,
            timeoutMs: stripeTimings.runtimeTimeoutMs,
        }).then(() => {
            if (!loaded()) {
                throw new Error('loadCryptoOnrampAndInitialize is not available after script load');
            }
            return global.loadCryptoOnrampAndInitialize;
        });
    }

    /** Held in a variable so tests can inject a fake coordinator, like the Banxa loader. */
    let loadStripeRuntime = function (publicKey) {
        return loadStripeConstructor().then((construct) =>
            construct(publicKey, { theme: 'stripe' }),
        );
    };
    const defaultStripeRuntimeLoader = loadStripeRuntime;

    // One coordinator per page, as iOS StripeSdkOwnership: the next opens after the last is destroyed.
    let stripeRuntimeTurn = Promise.resolve();

    function openStripeRuntime(publicKey, isActive) {
        const previous = stripeRuntimeTurn;
        let release;
        stripeRuntimeTurn = new Promise((resolve) => {
            release = resolve;
        });
        return previous.then(async () => {
            let coordinator;
            try {
                coordinator = await loadStripeRuntime(publicKey);
            } catch (e) {
                release();
                throw Object.assign(stripeError('scriptLoad'), { detail: e && e.detail });
            }
            let closed = false;
            const runtime = {
                coordinator,
                close() {
                    if (closed) return;
                    closed = true;
                    try {
                        if (coordinator && typeof coordinator.destroy === 'function') {
                            coordinator.destroy();
                        }
                    } catch (e) {
                        /* provider teardown must not throw into the SDK */
                    }
                    release();
                },
            };
            if (
                !coordinator ||
                STRIPE_RUNTIME_METHODS.some((method) => typeof coordinator[method] !== 'function')
            ) {
                runtime.close();
                throw stripeError('unavailable');
            }
            if (!isActive()) {
                runtime.close();
                throw stripeError('cancelled');
            }
            return runtime;
        });
    }

    // ---- the SDK's own surface

    function stripeSurface(hostElement, onCancel) {
        clearChildren(hostElement);
        const root = document.createElement('div');
        root.className = 'meld-stripe';
        root.style.display = 'grid';
        root.style.gap = '12px';
        const status = document.createElement('p');
        status.className = 'meld-stripe-status';
        status.setAttribute('role', 'status');
        const notice = document.createElement('p');
        notice.className = 'meld-stripe-notice';
        notice.hidden = true;
        const content = document.createElement('div');
        content.className = 'meld-stripe-content';
        const cancel = document.createElement('button');
        cancel.type = 'button';
        cancel.className = 'meld-stripe-cancel';
        cancel.textContent = 'Cancel';
        cancel.addEventListener('click', () => onCancel());
        root.append(status, notice, content, cancel);
        hostElement.appendChild(root);

        let pending = null;
        let closed = false;

        function wait(abandon) {
            const token = { abandon };
            pending = token;
            return token;
        }

        function done(token) {
            if (pending === token) pending = null;
            clearChildren(content);
        }

        function show(element) {
            clearChildren(content);
            content.appendChild(element);
        }

        function input(name) {
            const definition = STRIPE_FORM_FIELDS[name];
            const label = document.createElement('label');
            label.style.display = 'grid';
            label.style.gap = '4px';
            label.textContent = definition.label;
            const field = document.createElement('input');
            field.name = name;
            field.type = definition.type || 'text';
            field.maxLength = 255;
            field.spellcheck = false;
            field.setAttribute('autocomplete', definition.autocomplete);
            field.setAttribute('autocapitalize', 'off');
            if (definition.inputMode) field.setAttribute('inputmode', definition.inputMode);
            if (definition.placeholder) field.placeholder = definition.placeholder;
            label.appendChild(field);
            return { label, field };
        }

        return {
            progress(text) {
                if (!closed) status.textContent = text;
            },
            notice(text) {
                if (closed) return;
                notice.textContent = text || '';
                notice.hidden = !text;
            },
            wait,
            done,
            show,
            /** Rejects whatever is waiting for the customer. False when nothing was. */
            abandon() {
                if (!pending) return false;
                const token = pending;
                pending = null;
                clearChildren(content);
                token.abandon();
                return true;
            },
            form(title, names) {
                return new Promise((resolve, reject) => {
                    const form = document.createElement('form');
                    form.noValidate = true;
                    form.className = 'meld-stripe-form';
                    form.style.display = 'grid';
                    form.style.gap = '12px';
                    const fieldset = document.createElement('fieldset');
                    fieldset.style.display = 'grid';
                    fieldset.style.gap = '12px';
                    const legend = document.createElement('legend');
                    legend.textContent = title;
                    fieldset.appendChild(legend);
                    const fields = {};
                    for (const name of names) {
                        const { label, field } = input(name);
                        fields[name] = field;
                        fieldset.appendChild(label);
                    }
                    const error = document.createElement('p');
                    error.setAttribute('role', 'alert');
                    const submit = document.createElement('button');
                    submit.type = 'submit';
                    submit.textContent = 'Continue';
                    form.append(fieldset, error, submit);
                    const wipe = () => names.forEach((name) => (fields[name].value = ''));
                    const token = wait(() => {
                        wipe();
                        reject(stripeError('cancelled'));
                    });
                    form.addEventListener('submit', (event) => {
                        event.preventDefault();
                        if (pending !== token) return;
                        const values = {};
                        for (const name of names) {
                            const value = stripeNormalizedField(name, fields[name].value);
                            if (!stripeValidField(name, value)) {
                                error.textContent =
                                    'Check your ' +
                                    STRIPE_FORM_FIELDS[name].label.toLowerCase() +
                                    '.';
                                fields[name].focus();
                                return;
                            }
                            values[name] = value;
                        }
                        wipe();
                        done(token);
                        resolve(values);
                    });
                    show(form);
                    if (names.length) fields[names[0]].focus();
                });
            },
            /** `press` runs inside the click itself, where the browser still sees the gesture. */
            prompt(title, text, action, press) {
                return new Promise((resolve, reject) => {
                    const box = document.createElement('div');
                    box.className = 'meld-stripe-prompt';
                    const heading = document.createElement('p');
                    heading.textContent = title;
                    const body = document.createElement('p');
                    body.textContent = text;
                    const button = document.createElement('button');
                    button.type = 'button';
                    button.textContent = action;
                    box.append(heading, body, button);
                    const token = wait(() => reject(stripeError('cancelled')));
                    button.addEventListener('click', () => {
                        if (pending !== token) return;
                        done(token);
                        resolve(press());
                    });
                    show(box);
                });
            },
            close() {
                closed = true;
                const token = pending;
                pending = null;
                if (token) token.abandon();
                clearChildren(hostElement);
            },
        };
    }

    // ---- the flow

    function mountStripe(order, _details, hostElement, handlers) {
        const stripe = stripeOrder(order);
        const orderId = order.id;
        const client = createActionClient(stripe.actions);
        let active = true;
        let cancelling = false;
        let stopped = false;
        let financialStarted = false;
        let session = null;
        let prefill = null;
        let identityPrefillUsed = false;
        let runtime = null;
        let journal = null;
        let releaseOrder = null;
        const surface = stripeSurface(hostElement, cancel);
        surface.progress('Preparing checkout');

        function check() {
            if (!active) throw stripeError('cancelled');
        }

        function mayHaveFinancialAttempt() {
            if (financialStarted) return true;
            try {
                return journal ? journal.record().submissionStarted : false;
            } catch (e) {
                return true;
            }
        }

        async function action(operation, fields, key, attempt) {
            for (let tries = 0; ; tries++) {
                check();
                try {
                    const value = await client.send(operation, fields || {}, key);
                    check();
                    return stripeResponse(value);
                } catch (e) {
                    if (!active || (e && e.kind === 'closed')) throw stripeError('cancelled');
                    if (e && e.kind === 'transport' && tries === 0) {
                        if (attempt) attempt.retried = true;
                        continue;
                    }
                    throw e;
                }
            }
        }

        async function readSubmission() {
            return stripeSubmission(await action('READ_SUBMISSION'));
        }

        async function sdk(method, ...args) {
            check();
            if (!runtime) throw stripeError('unavailable');
            let value;
            try {
                value = await runtime.coordinator[method](...args);
            } catch (e) {
                check();
                throw e && e.name === 'MeldStripeError' ? e : stripeError('unavailable');
            }
            check();
            return value;
        }

        /** A runtime call that returns an element to show and answers through a callback. */
        function component(method, argument, elementOptional) {
            check();
            if (!runtime) return Promise.reject(stripeError('unavailable'));
            const coordinator = runtime.coordinator;
            return new Promise((resolve, reject) => {
                let settled = false;
                let element = null;
                const token = surface.wait(() => settle(() => reject(stripeError('cancelled'))));
                function settle(finish) {
                    if (settled) return;
                    settled = true;
                    surface.done(token);
                    if (element && element.parentNode) element.remove();
                    finish();
                }
                Promise.resolve()
                    .then(() =>
                        coordinator[method](argument, (result) => {
                            if (active) settle(() => resolve(result));
                        }),
                    )
                    .then((value) => {
                        if (settled) {
                            if (value && typeof value.remove === 'function') value.remove();
                            return;
                        }
                        if (value == null && elementOptional) return;
                        if (!value || value.nodeType !== 1) {
                            settle(() => reject(stripeError('unavailable')));
                            return;
                        }
                        element = value;
                        surface.show(element);
                    })
                    .catch(() =>
                        settle(() => reject(stripeError(active ? 'unavailable' : 'cancelled'))),
                    );
            });
        }

        async function register(email) {
            if (prefill && prefill.phone) {
                try {
                    await sdk(
                        'registerLinkUser',
                        email,
                        prefill.phone,
                        'US',
                        prefill.fullName || undefined,
                    );
                    return;
                } catch (e) {
                    if (e.kind === 'cancelled') throw e;
                    check();
                }
            }
            const values = await surface.form('Create your Link account', ['name', 'phone']);
            await sdk('registerLinkUser', email, values.phone, 'US', values.name || undefined);
        }

        async function authenticate(state) {
            surface.progress('Connecting to Link');
            let prepared = await action('PREPARE_CUSTOMER_AUTHORIZATION', {}, uuid());
            if (stripeRequiresRegistration(prepared)) {
                if (
                    state !== 'BOOTSTRAP' ||
                    stripe.flow !== 'REGISTER' ||
                    session ||
                    financialStarted
                ) {
                    throw stripeError('invalidResponse');
                }
                // Link authorizes the Meld customer's email, so a typed one could never match.
                if (!prefill) throw stripeError('registrationUnavailable');
                await register(prefill.email);
                prepared = await action('PREPARE_CUSTOMER_AUTHORIZATION', {}, uuid());
                if (stripeRequiresRegistration(prepared)) throw stripeError('invalidResponse');
            }
            const intent = stripeAuthorizationIntent(prepared);
            surface.progress('Sign in to Link');
            const result = await component('authenticate', intent, true);
            check();
            if (isPlainObject(result) && ['abandoned', 'declined'].includes(result.result)) {
                throw stripeError('cancelled');
            }
            const customer =
                isPlainObject(result) && result.result === 'success'
                    ? stripeIdentifier(result.crypto_customer_id, 'crc_')
                    : null;
            if (!customer) throw stripeError('invalidResponse');
            stripeCustomerAction(
                await action('COMPLETE_CUSTOMER_LINK', { customerHandle: customer }, uuid()),
                false,
            );
        }

        async function identityForm(fields) {
            const all = fields.length === 0;
            const wanted = [];
            for (const [code, name] of [
                ['FIRST_NAME', 'firstName'],
                ['LAST_NAME', 'lastName'],
                ['DATE_OF_BIRTH', 'birthday'],
                ['ID_NUMBER', 'idNumber'],
            ]) {
                if (all || fields.includes(code)) wanted.push(name);
            }
            const needsAddress = all || fields.some((field) => field.startsWith('ADDRESS_'));
            if (needsAddress) wanted.push(...STRIPE_ADDRESS_FORM);
            if (!wanted.length) throw stripeError('invalidResponse');
            const values = await surface.form(
                wanted.length === 1 && wanted[0] === 'idNumber'
                    ? 'Confirm your identity'
                    : 'Verify your identity',
                wanted,
            );
            return {
                firstName: values.firstName,
                lastName: values.lastName,
                idNumber: values.idNumber,
                birthday: values.birthday ? stripeBirthday(values.birthday) : undefined,
                address: needsAddress
                    ? {
                          line1: values.line1,
                          line2: values.line2 || null,
                          city: values.city,
                          state: values.state,
                          postalCode: values.postalCode,
                      }
                    : undefined,
            };
        }

        /** Prefill is used once; after Stripe rejects it the customer is asked for everything. */
        async function identity(fields, prefilled) {
            const known = prefill && prefill.identity;
            if (!prefilled || identityPrefillUsed || !known) {
                return identityForm(identityPrefillUsed ? [] : fields);
            }
            identityPrefillUsed = true;
            const wanted = fields.length ? fields : STRIPE_IDENTITY_FIELDS;
            const covered = (field) =>
                field === 'FIRST_NAME'
                    ? !!known.firstName
                    : field === 'LAST_NAME'
                      ? !!known.lastName
                      : field === 'DATE_OF_BIRTH'
                        ? !!known.birthday
                        : field.startsWith('ADDRESS_') && !!known.address;
            const remaining = wanted.filter((field) => !covered(field));
            const input = remaining.length ? await identityForm(remaining) : {};
            if (wanted.includes('FIRST_NAME') && covered('FIRST_NAME')) {
                input.firstName = known.firstName;
            }
            if (wanted.includes('LAST_NAME') && covered('LAST_NAME')) {
                input.lastName = known.lastName;
            }
            if (wanted.includes('DATE_OF_BIRTH') && covered('DATE_OF_BIRTH')) {
                input.birthday = known.birthday;
            }
            if (wanted.some((field) => field.startsWith('ADDRESS_')) && known.address) {
                input.address = known.address;
            }
            return input;
        }

        async function submitIdentity(input) {
            surface.progress('Checking your details');
            await sdk('submitKycInfo', stripeKycInfo(input));
        }

        async function verifyDocuments() {
            const result = await surface.prompt(
                'Verify your identity',
                'Stripe needs a photo of your ID. You may be asked for camera access.',
                'Continue',
                () => sdk('verifyDocuments'),
            );
            if (isPlainObject(result) && result.result === 'abandoned') {
                throw stripeError('cancelled');
            }
            if (!isPlainObject(result) || result.result !== 'success') {
                throw stripeError('invalidResponse');
            }
        }

        async function verifyCustomer() {
            for (let i = 0; i < STRIPE_LOOPS; i++) {
                const result = stripeCustomerAction(await action('READ_CUSTOMER_STATUS'), true);
                const state = result.status + '/' + result.next;
                if (result.status === 'VERIFIED') return true;
                if (
                    state === 'NOT_STARTED/SDK_COLLECT_KYC' ||
                    state === 'REJECTED/SDK_COLLECT_KYC'
                ) {
                    await submitIdentity(
                        await identity(result.missingFields, result.status === 'NOT_STARTED'),
                    );
                } else if (result.next === 'SDK_VERIFY_IDENTITY') {
                    await verifyDocuments();
                } else if (state === 'PENDING/RETRY') {
                    surface.progress('Checking your verification');
                    await new Promise((resolve) =>
                        setTimeout(resolve, stripeTimings.pendingPauseMs),
                    );
                    check();
                } else {
                    throw stripeError('invalidResponse');
                }
            }
            return false;
        }

        /** Advisory: Stripe raises limits through step-up verification during checkout. */
        async function readLimits() {
            let result;
            try {
                result = await action('READ_LIMITS');
            } catch (e) {
                if (e.kind === 'cancelled') throw e;
                return;
            }
            const ceiling = stripeLimitCeiling(result.limits);
            if (ceiling !== null && stripe.amount > ceiling) {
                surface.notice(
                    'This amount is above your current limit, so Stripe may ask you to verify more details.',
                );
            }
        }

        async function registerWallet() {
            await sdk('registerWalletAddress', stripe.walletAddress, stripe.walletNetwork);
        }

        async function collectPayment() {
            const applePay = stripe.method === 'APPLE_PAY';
            for (let i = 0; i < STRIPE_PAYMENT_PRESENTATIONS; i++) {
                surface.progress(applePay ? 'Pay with Apple Pay' : 'Add your card');
                const result = await component('collectPaymentMethod', {
                    payment_method_types: ['card'],
                    wallets: { applePay: applePay ? 'always' : 'never', googlePay: 'never' },
                });
                check();
                const token = isPlainObject(result)
                    ? stripeIdentifier(result.cryptoPaymentToken, 'cpt_')
                    : null;
                if (!token) throw stripeError('invalidResponse');
                const method = result.paymentMethodDetails;
                const wallet =
                    isPlainObject(method) && method.type === 'card' && isPlainObject(method.card)
                        ? method.card.wallet
                        : undefined;
                if (
                    applePay
                        ? isPlainObject(wallet) && wallet.type === 'apple_pay'
                        : wallet === null
                ) {
                    surface.notice('');
                    return token;
                }
                surface.notice(
                    applePay ? 'Use Apple Pay for this order.' : 'Use a card for this order.',
                );
            }
            throw stripeError('paymentMethodMismatch');
        }

        async function continueSession(initial) {
            let result = initial;
            for (let i = 0; i < STRIPE_LOOPS; i++) {
                check();
                const expected = session;
                if (!expected || result.session !== expected) throw stripeError('invalidResponse');
                const state = result.status + '/' + result.next;
                if (
                    state === 'QUOTE_READY/CONFIRM_PAYMENT' ||
                    state === 'REQUIRES_PAYMENT/CONFIRM_PAYMENT'
                ) {
                    surface.progress('Confirming your payment');
                    let followUp = null;
                    let authorizationRequired = false;
                    let callbackRunning = false;
                    const provideSecret = async (requested) => {
                        check();
                        if (callbackRunning || requested !== expected) {
                            throw stripeError('invalidResponse');
                        }
                        if (followUp || authorizationRequired) throw stripeError('actionRequired');
                        callbackRunning = true;
                        try {
                            const callbackInvocationId = uuid();
                            let response;
                            try {
                                response = await action(
                                    'CONFIRM_PAYMENT',
                                    { callbackInvocationId },
                                    uuid(),
                                );
                            } catch (e) {
                                if (e.kind === 'action' && e.code === 'AUTHORIZATION_REQUIRED') {
                                    authorizationRequired = true;
                                    throw stripeError('actionRequired');
                                }
                                throw e;
                            }
                            if (response.session !== requested) {
                                throw stripeError('invalidResponse');
                            }
                            if (STRIPE_CHECKOUT_FOLLOW_UPS.has(response.next)) {
                                followUp = response;
                                throw stripeError('actionRequired');
                            }
                            return stripeCheckoutSecret(response, requested);
                        } finally {
                            callbackRunning = false;
                        }
                    };
                    let outcome;
                    let failure = null;
                    try {
                        outcome = await sdk('performCheckout', expected, provideSecret);
                    } catch (e) {
                        failure = e;
                    }
                    check();
                    if (followUp) {
                        result = followUp;
                        continue;
                    }
                    if (authorizationRequired) {
                        // A runtime that swallowed the refusal cannot turn it into success.
                        if (isPlainObject(outcome) && outcome.successful === true) {
                            throw stripeError('authorizationRequired');
                        }
                        await authenticate('REAUTHORIZE');
                        result = await action('REFRESH_QUOTE', {}, uuid());
                        continue;
                    }
                    if (failure) throw failure;
                    if (!isPlainObject(outcome) || outcome.successful !== true) {
                        throw stripeError('cancelled');
                    }
                    return observe(await readSubmission());
                }
                if (state === 'REJECTED/SDK_COLLECT_KYC') {
                    await submitIdentity(await identityForm([]));
                    if (!(await verifyCustomer())) return { outcome: 'verificationPending' };
                } else if (state === 'REJECTED/SDK_VERIFY_IDENTITY') {
                    await verifyDocuments();
                    if (!(await verifyCustomer())) return { outcome: 'verificationPending' };
                } else if (state === 'REQUIRES_PAYMENT/SDK_REGISTER_WALLET') {
                    await registerWallet();
                } else if (
                    state === 'FULFILLMENT_PROCESSING/NONE' ||
                    state === 'FULFILLMENT_COMPLETE/COMPLETE'
                ) {
                    return observe(await readSubmission());
                } else if (state !== 'REQUIRES_PAYMENT/REFRESH_QUOTE') {
                    throw stripeError('invalidResponse');
                }
                result = await action('REFRESH_QUOTE', {}, uuid());
            }
            throw stripeError('invalidResponse');
        }

        function observe(submission) {
            check();
            if (submission.kind !== 'notStarted') financialStarted = true;
            journal.observeSubmission();
            const outcome = {
                completed: 'completed',
                submitted: 'submitted',
                inProgress: 'pending',
                unknown: 'pending',
                failed: 'rejected',
                expired: 'expired',
            }[submission.kind];
            if (!outcome) throw stripeError('alreadyAttempted');
            return { outcome };
        }

        async function run() {
            const read = await action('READ_SUBMISSION');
            const submission = stripeSubmission(read);
            prefill = read.prefill;
            let authentication;
            if (submission.kind === 'notStarted') {
                if (journal.record().submissionStarted) throw stripeError('alreadyAttempted');
                if (stripe.method === 'APPLE_PAY' && !applePayAvailable()) {
                    return { outcome: 'applePayUnavailable' };
                }
                authentication = submission.authentication;
            } else if (submission.kind === 'resumeSession') {
                session = submission.session;
                financialStarted = true;
                journal.observeSubmission();
                authentication = submission.authentication;
            } else {
                return observe(submission);
            }
            runtime = await openStripeRuntime(stripe.publicKey, () => active);
            check();
            try {
                await authenticate(authentication);
                if (!(await verifyCustomer())) return { outcome: 'verificationPending' };
                if (session) {
                    return await continueSession(await action('REFRESH_QUOTE', {}, uuid()));
                }
                await readLimits();
                await registerWallet();
                const token = await collectPayment();
                const key = journal.claimSubmission();
                financialStarted = true;
                surface.progress('Starting your payment');
                const attempt = { retried: false };
                let created;
                try {
                    created = await action(
                        'CREATE_PAYMENT_SESSION',
                        { paymentToken: token },
                        key,
                        attempt,
                    );
                } catch (e) {
                    if (e.kind === 'action' && e.code === 'PROVIDER_REJECTED' && !attempt.retried) {
                        return { outcome: 'refused', detail: 'create:PROVIDER_REJECTED' };
                    }
                    throw e;
                }
                if (!created.session) {
                    if (created.status === 'FAILED' && created.next === 'START_NEW_ORDER') {
                        return { outcome: 'refused', detail: 'create:START_NEW_ORDER' };
                    }
                    throw stripeError('invalidResponse');
                }
                session = created.session;
                return await continueSession(created);
            } catch (e) {
                // Leaving a provider screen can race a payment; only the server can resolve that.
                if (e.kind !== 'cancelled' || !active) throw e;
                return financialStarted
                    ? observe(await readSubmission())
                    : { outcome: 'cancelled' };
            }
        }

        /** iOS StripePaymentSession.events, plus PAYMENT_METHOD_UNAVAILABLE without Apple Pay. */
        function deliver(result) {
            const fail = (code, detail, message) =>
                emit(handlers, 'onError', meldError(orderId, code, detail, message));
            const pending = () => emit(handlers, 'onStatusChange', { orderId, status: 'pending' });
            if (result.error) {
                emit(handlers, 'onError', stripeFailure(result.error));
                return;
            }
            switch (result.outcome) {
                case 'cancelled':
                    emit(handlers, 'onCancel', { orderId });
                    return;
                case 'completed':
                    emit(handlers, 'onStatusChange', { orderId, status: 'completed' });
                    return;
                case 'submitted':
                    pending();
                    emit(handlers, 'onPaymentSubmitted', { orderId });
                    return;
                case 'rejected':
                    fail(ERROR_CODES.PAYMENT_REJECTED, 'submission:FAILED');
                    return;
                case 'refused':
                    fail(ERROR_CODES.PAYMENT_REJECTED, result.detail);
                    return;
                case 'expired':
                    fail(
                        ERROR_CODES.PAYMENT_REJECTED,
                        'submission:EXPIRED',
                        'The payment expired before it completed. Choose another payment option.',
                    );
                    return;
                case 'applePayUnavailable':
                    fail(
                        ERROR_CODES.PAYMENT_METHOD_UNAVAILABLE,
                        undefined,
                        'Apple Pay is not available in this browser. Offer another option.',
                    );
                    return;
                case 'verificationPending':
                    if (!mayHaveFinancialAttempt()) {
                        fail(ERROR_CODES.VERIFICATION_PENDING);
                        return;
                    }
                // falls through
                default:
                    pending();
                    fail(ERROR_CODES.PAYMENT_OUTCOME_UNKNOWN);
            }
        }

        function stripeFailure(error) {
            const kind = error && error.kind;
            if (kind === 'scriptLoad') {
                return {
                    orderId,
                    code: ERROR_CODES.PROVIDER_LOAD_FAILED,
                    message: 'Failed to load provider script: ' + STRIPE_SCRIPT,
                    // Probe verdict (server-responded vs request-blocked) or the timeout.
                    detail: error.detail,
                    recoverable: true,
                };
            }
            const detail =
                kind === 'action'
                    ? 'action:' + error.code
                    : kind === 'http'
                      ? 'http:' + error.status
                      : kind || 'unexpected';
            if (kind === 'busy') {
                return meldError(
                    orderId,
                    ERROR_CODES.PAYMENT_OUTCOME_UNKNOWN,
                    detail,
                    'This order is open in another window, which may be paying it. Track the existing order without paying again.',
                );
            }
            if (!mayHaveFinancialAttempt()) {
                return meldError(
                    orderId,
                    ERROR_CODES.PRESENTATION_FAILED,
                    detail,
                    'This payment could not be started. No payment was attempted.',
                );
            }
            return meldError(
                orderId,
                ERROR_CODES.PAYMENT_OUTCOME_UNKNOWN,
                detail,
                'This payment could not be continued. Review the existing order before trying again.',
            );
        }

        function stop() {
            if (stopped) return;
            stopped = true;
            active = false;
            client.close();
            surface.close();
            if (runtime) runtime.close();
            if (releaseOrder) releaseOrder();
        }

        /** The SDK's Cancel. A waiting form or Stripe screen ends; otherwise the session does. */
        function cancel() {
            if (!active || cancelling) return;
            if (surface.abandon()) return;
            cancelling = true;
            deliver({ outcome: mayHaveFinancialAttempt() ? 'pending' : 'cancelled' });
            stop();
        }

        async function start() {
            if (!active) return;
            // As on iOS, onReady means the SDK's own surface is up; Stripe's runtime loads later.
            emit(handlers, 'onReady', { orderId });
            if (!active) return;
            let result;
            try {
                const name = await attemptName(stripe.actions);
                check();
                journal = attemptJournal(stripe.actions, name);
                releaseOrder = await acquireOrder(name, stripeTimings.lockWaitMs);
                if (!active && releaseOrder) releaseOrder();
                check();
                if (!releaseOrder) throw stripeError('busy');
                result = await run();
            } catch (e) {
                result = { error: e };
            }
            if (cancelling || !active) return;
            surface.close();
            deliver(result);
            stop();
        }

        setTimeout(start, 0);

        return {
            mode: 'embedded',
            unmount() {
                stop();
            },
        };
    }

    // ------------------------------------------------------------------ coinme
    // Coinme card. Coinme's Risk SDK (Sardine) tags the device first, and its session id travels
    // with the new card and with the payment. The SDK draws the saved-card picker and the billing
    // state input; the card and the rest of the address are Coinme Vault's secure fields,
    // VGS iframes, so PAN, CVC and expiry never reach this file. A new card is added to the
    // customer at Coinme, then CREATE_PAYMENT_SESSION pays with it. Coinme verifies a new card for
    // about a minute, and until it has the backend answers PENDING/RETRY.

    const COINME_OPERATIONS = ['CREATE_CUSTOMER_AUTH_TOKEN', 'CREATE_PAYMENT_SESSION'];
    const COINME_RISK_API = {
        sandbox: 'https://caas-staging.coinme.com',
        live: 'https://caas.coinme.com',
    };
    // Coinme's answer to adding a card the customer has already saved.
    const COINME_CARD_IN_USE = '231-400-313-600';
    const COINME_LOAD_TIMEOUT_MS = 30000;
    const COINME_RETRY_PAUSE_MS = 5000;
    const COINME_VERIFICATION_LIMIT_MS = 180000;
    const COINME_ID = /^[A-Za-z0-9_-]{1,64}$/;
    const COINME_TOKEN = /^[\x21-\x7e]{1,16384}$/;
    const COINME_ERROR_CODE = /^[0-9A-Za-z]{1,8}(?:-[0-9A-Za-z]{1,8}){1,5}$/;
    const COINME_SDK_FUNCTIONS = [
        'createCoinmeVault',
        'submitPaymentMethod',
        'setupCoinmeRiskEngine',
        'getSessionTag',
        'updateCoinmeRiskEngine',
        'clearSessionKey',
    ];
    // The action codes that say what happened. Any other failure once the payment was requested may
    // have paid.
    const COINME_ACTION_CODES = Object.freeze({
        PROVIDER_REJECTED: ERROR_CODES.PAYMENT_REJECTED,
        ORDER_STATE_CHANGED: ERROR_CODES.ORDER_STATE_CHANGED,
        PROVIDER_UNAVAILABLE: ERROR_CODES.PROVIDER_LOAD_FAILED,
        INVALID_REQUEST: ERROR_CODES.PRESENTATION_FAILED,
        AUTHORIZATION_REQUIRED: ERROR_CODES.PRESENTATION_FAILED,
        STATE_NOT_FOUND: ERROR_CODES.PRESENTATION_FAILED,
    });
    const COINME_MESSAGES = Object.freeze({
        load: "Coinme's card checkout could not be loaded. No payment was attempted.",
        card: 'Coinme could not add this card. Choose another payment option.',
        verification:
            'Coinme is still verifying this card. No payment was attempted. Try again later.',
        unavailable:
            'Coinme is not available right now. Review the existing order before trying again.',
    });
    // Vault fields are VGS iframes mounted into a container; the others are the SDK's own inputs.
    const COINME_FORM = [
        {
            key: 'pan',
            label: 'Card number',
            error: 'Enter a valid card number',
            vault: 'createCardNumberField',
        },
        {
            key: 'expiry',
            label: 'Expiry date',
            error: 'Enter a valid expiry date',
            vault: 'createExpiryField',
            options: { placeholder: 'MM / YYYY' },
        },
        {
            key: 'cvc',
            label: 'Security code',
            error: 'Enter the security code',
            vault: 'createCvcField',
        },
        {
            key: 'address1',
            label: 'Street address',
            error: 'Required',
            vault: 'createTextField',
            options: { validations: ['required'], autoComplete: 'address-line1' },
        },
        {
            key: 'address2',
            label: 'Apartment or suite (optional)',
            vault: 'createTextField',
            options: { autoComplete: 'address-line2' },
        },
        {
            key: 'city',
            label: 'City',
            error: 'Required',
            vault: 'createTextField',
            options: { validations: ['required'], autoComplete: 'address-level2' },
        },
        {
            key: 'state',
            label: 'State',
            error: 'Two letters',
            placeholder: 'CO',
            autocomplete: 'address-level1',
        },
        {
            key: 'zipcode',
            label: 'ZIP code',
            error: 'Enter a valid ZIP code',
            vault: 'createTextField',
            options: { validations: ['required', 'postal_code/us'], autoComplete: 'postal-code' },
        },
    ];
    // The form's sections and their rows, by field key, in COINME_FORM order.
    const COINME_LAYOUT = [
        ['Card details', [['pan'], ['expiry', 'cvc']]],
        ['Billing address', [['address1'], ['address2'], ['city', 'state', 'zipcode']]],
    ];
    const COINME_COLUMNS = {
        1: 'minmax(0, 1fr)',
        2: 'minmax(0, 1fr) minmax(0, 1fr)',
        3: 'minmax(0, 1.4fr) minmax(0, 0.8fr) minmax(0, 1fr)',
    };
    // Styles go on elements, not in a <style> sheet, so an integrator's style-src CSP need not change.
    const COINME_FONT =
        "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif";
    const COINME_COLORS = Object.freeze({
        text: '#111827',
        muted: '#6b7280',
        line: '#d1d5db',
        focus: '#2563eb',
        selected: '#eff6ff',
        error: '#b42318',
        errorBackground: '#fef3f2',
        status: '#f3f4f6',
    });

    /** The vendored Coinme SDKs, evaluated on first use. A variable, so tests can inject fakes. */
    function defaultCoinmeSdkLoader() {
        return Promise.resolve().then(() => globalThis.MeldCoinmeVendor.load());
    }
    let loadCoinmeSdk = defaultCoinmeSdkLoader;
    let coinmeSurfaces = 0;

    function coinmeError(kind, extra) {
        const error = new Error('Coinme checkout stopped: ' + kind);
        error.name = 'MeldCoinmeError';
        error.kind = kind;
        return Object.assign(error, extra);
    }

    function coinmeText(value, pattern) {
        return typeof value === 'string' && pattern.test(value) ? value : null;
    }

    /** A saved card the picker can show and pay with, or null. */
    function coinmeSavedCard(card) {
        if (
            !isPlainObject(card) ||
            !coinmeText(card.paymentMethodId, COINME_ID) ||
            !coinmeText(card.last4, /^[0-9]{4}$/)
        ) {
            return null;
        }
        return Object.freeze({
            paymentMethodId: card.paymentMethodId,
            last4: card.last4,
            brand: coinmeText(card.brand, /^[A-Za-z][A-Za-z .-]{0,31}$/),
            bin: coinmeText(card.bin, /^[0-9]{6,8}$/),
            expMonth: coinmeText(card.expMonth, /^(?:0?[1-9]|1[0-2])$/),
            expYear: coinmeText(card.expYear, /^[0-9]{2}(?:[0-9]{2})?$/),
        });
    }

    /** Validated inputs for the adapter. */
    function coinmeOrder(order) {
        const decline = (reason) => coinmeError('invalidOrder', { reason });
        const details = order && order.paymentMethodResponseDetails;
        const data = isPlainObject(details) ? details.sdkSessionData : null;
        if (!isPlainObject(data)) throw decline('it is not a Coinme card order');
        const session = {
            browserToken: coinmeText(details.sdkSessionToken, COINME_TOKEN),
            customerId: coinmeText(data.customerId, COINME_ID),
            providerId: coinmeText(data.paymentProviderId, COINME_ID),
            riskClientId: coinmeText(data.riskClientId, COINME_TOKEN),
            riskPartnerId: coinmeText(data.riskPartnerId, COINME_ID),
        };
        if (
            Object.values(session).some((value) => !value) ||
            !hasOwn(COINME_RISK_API, data.environment) ||
            (data.savedCards != null && !Array.isArray(data.savedCards)) ||
            (data.paymentProcessAssociation != null && data.paymentProcessAssociation !== 'SELL')
        ) {
            throw decline('its Coinme session is not usable');
        }
        let actions;
        try {
            actions = paymentActionDescriptor(order);
        } catch (e) {
            throw decline('its payment actions are not valid');
        }
        if (COINME_OPERATIONS.some((operation) => actions.operations[operation] !== true)) {
            throw decline('its payment actions do not declare the Coinme operations');
        }
        return Object.freeze(
            Object.assign(session, {
                environment: data.environment,
                payout: data.paymentProcessAssociation === 'SELL',
                savedCards: Object.freeze(
                    (data.savedCards || []).map(coinmeSavedCard).filter(Boolean),
                ),
                actions,
                toString: () => '[MeldCoinmeOrder REDACTED]',
            }),
        );
    }

    function coinmeAdmissionError(order) {
        try {
            coinmeOrder(order);
            return null;
        } catch (e) {
            return e.reason || 'it is not a Coinme card order';
        }
    }

    function coinmeSdk(sdk) {
        if (
            !sdk ||
            COINME_SDK_FUNCTIONS.some((name) => typeof sdk[name] !== 'function') ||
            !isPlainObject(sdk.FlowType) ||
            typeof sdk.FlowType.CardLinking !== 'string' ||
            typeof sdk.FlowType.CardTransaction !== 'string' ||
            !isPlainObject(sdk.VAULT_FIELD_NAMES) ||
            typeof sdk.VAULT_FIELD_NAMES.pan !== 'string'
        ) {
            throw new Error('the Coinme SDKs are not available');
        }
        return sdk;
    }

    function coinmeBrand(value) {
        const key = typeof value === 'string' ? value.toLowerCase().replace(/[^a-z]/g, '') : '';
        return key === 'americanexpress' ? 'amex' : key;
    }

    /** The one saved card the typed card can be: by last4, and BIN and brand where VGS has them. */
    function coinmeMatchingCard(pan, cards) {
        const last4 = isPlainObject(pan) ? coinmeText(pan.last4, /^[0-9]{4}$/) : null;
        if (!last4) return null;
        const bin = coinmeText(pan.bin, /^[0-9]{6,8}$/);
        const brand = coinmeBrand(pan.cardType);
        const matches = cards.filter(
            (card) =>
                card.last4 === last4 &&
                (!bin || !card.bin || card.bin.slice(0, 6) === bin.slice(0, 6)) &&
                (!brand || !card.brand || coinmeBrand(card.brand) === brand),
        );
        return matches.length === 1 ? matches[0] : null;
    }

    /** The first Coinme error code on a Vault failure: a 2xx error envelope, or an error body. */
    function coinmeVaultCode(error) {
        if (!isPlainObject(error)) return null;
        const body = isPlainObject(error.cause) ? error.cause.data : null;
        let envelope = isPlainObject(error.errorResponse) ? error.errorResponse : body;
        if (isPlainObject(envelope) && isPlainObject(envelope.errorResponse)) {
            envelope = envelope.errorResponse;
        }
        const first =
            isPlainObject(envelope) && Array.isArray(envelope.errorData)
                ? envelope.errorData[0]
                : null;
        return isPlainObject(first) ? coinmeText(first.errorCode, COINME_ERROR_CODE) : null;
    }

    function coinmeVaultStatus(error) {
        if (!isPlainObject(error)) return undefined;
        if (error.kind === 'server') return error.status;
        return isPlainObject(error.errorResponse) ? error.errorResponse.httpStatus : undefined;
    }

    function coinmeVaultFailure(error, code) {
        const status = coinmeVaultStatus(error);
        if (status === 401 || status === 403) {
            return coinmeError('authorization', { detail: 'vault:' + status });
        }
        const kind = isPlainObject(error) ? error.kind : undefined;
        if (code || kind === 'caas') {
            return coinmeError('card', { detail: 'vault:' + (code || kind) });
        }
        const known = ['network', 'server', 'unknown'].includes(kind) ? kind : 'unknown';
        return coinmeError('load', {
            detail: 'vault:' + (known === 'server' && status ? 'http:' + status : known),
        });
    }

    /** The shared code, detail and message for a failure, given whether payment was requested. */
    function coinmeFailure(error, paymentRequested) {
        const kind = error && error.kind;
        switch (kind) {
            case 'load':
                return [ERROR_CODES.PROVIDER_LOAD_FAILED, error.detail, COINME_MESSAGES.load];
            case 'card':
                return [ERROR_CODES.PAYMENT_REJECTED, error.detail, COINME_MESSAGES.card];
            case 'authorization':
                return [ERROR_CODES.PRESENTATION_FAILED, error.detail];
            case 'verificationPending':
                return [
                    ERROR_CODES.VERIFICATION_PENDING,
                    'action:PENDING',
                    COINME_MESSAGES.verification,
                ];
        }
        const detail =
            kind === 'action'
                ? 'action:' + error.code
                : kind === 'http'
                  ? 'http:' + error.status
                  : typeof kind === 'string'
                    ? kind
                    : 'unexpected';
        if (kind === 'action' && hasOwn(COINME_ACTION_CODES, error.code)) {
            const code = COINME_ACTION_CODES[error.code];
            return [
                code,
                detail,
                code === ERROR_CODES.PROVIDER_LOAD_FAILED ? COINME_MESSAGES.unavailable : undefined,
            ];
        }
        return [
            paymentRequested && kind !== 'invalidRequest'
                ? ERROR_CODES.PAYMENT_OUTCOME_UNKNOWN
                : ERROR_CODES.PRESENTATION_FAILED,
            detail,
        ];
    }

    function coinmeCardText(card) {
        const brand = card.brand || 'Card';
        const expiry =
            card.expMonth && card.expYear
                ? card.expMonth.padStart(2, '0') + '/' + card.expYear.slice(-2)
                : null;
        return {
            shown: brand + ' •••• ' + card.last4 + (expiry ? '  ' + expiry : ''),
            spoken: brand + ' ending in ' + card.last4 + (expiry ? ', expires ' + expiry : ''),
        };
    }

    function coinmeBilling(state) {
        const value = state.trim().toUpperCase();
        return /^[A-Z]{2}$/.test(value) ? { state: value } : null;
    }

    // ---- the SDK's own surface

    function coinmeStyled(element, styles) {
        Object.assign(element.style, styles);
        return element;
    }

    /** VGS styles the input inside each secure field's iframe from this. */
    function coinmeFieldCss() {
        return {
            'font-family': COINME_FONT,
            'font-size': '16px',
            color: COINME_COLORS.text,
            '&::placeholder': { color: '#9ca3af' },
        };
    }

    function coinmeSurface(hostElement, cards, payout, on) {
        clearChildren(hostElement);
        const id = 'meld-coinme-' + ++coinmeSurfaces;
        const colors = COINME_COLORS;
        const element = (tag, className, styles) => {
            const created = coinmeStyled(document.createElement(tag), styles || {});
            if (className) created.className = className;
            return created;
        };
        // An inline display would override the hidden attribute, so both move together.
        const show = (target, visible, display) => {
            target.hidden = !visible;
            target.style.display = visible ? display : 'none';
        };
        const box = {
            boxSizing: 'border-box',
            width: '100%',
            height: '44px',
            padding: '0 12px',
            border: '1px solid ' + colors.line,
            borderRadius: '8px',
            background: '#fff',
        };
        const message = (className, background, color) =>
            element('p', className, {
                margin: '0',
                padding: '10px 12px',
                borderRadius: '8px',
                background,
                color,
                fontSize: '14px',
            });

        const root = element('div', 'meld-coinme', {
            display: 'grid',
            gap: '16px',
            fontFamily: COINME_FONT,
            fontSize: '15px',
            lineHeight: '1.4',
            color: colors.text,
        });
        const status = message('meld-coinme-status', colors.status, colors.muted);
        status.setAttribute('role', 'status');
        show(status, false, 'block');
        const notice = message('meld-coinme-notice', colors.errorBackground, colors.error);
        notice.setAttribute('role', 'alert');
        show(notice, false, 'block');
        const content = element('div', 'meld-coinme-content', { display: 'grid', gap: '24px' });
        const pay = element('button', 'meld-coinme-pay', {
            width: '100%',
            height: '48px',
            border: '0',
            borderRadius: '10px',
            background: colors.text,
            color: '#fff',
            font: '600 16px ' + COINME_FONT,
            cursor: 'pointer',
        });
        pay.type = 'button';
        pay.textContent = payout ? 'Use this card' : 'Pay';
        pay.addEventListener('click', () => on.pay());
        const payable = (enabled) => {
            pay.disabled = !enabled;
            pay.style.opacity = enabled ? '1' : '0.4';
        };
        payable(false);

        const radios = [];
        const choices = [];
        const mark = () => {
            for (const [radio, label] of choices) {
                label.style.borderColor = radio.checked ? colors.focus : colors.line;
                label.style.background = radio.checked ? colors.selected : '#fff';
            }
        };
        if (cards.length) {
            const picker = element('fieldset', 'meld-coinme-cards', {
                display: 'grid',
                gap: '8px',
                margin: '0',
                padding: '0',
                border: '0',
                minWidth: '0',
            });
            const legend = element('legend', null, { padding: '0 0 8px', fontWeight: '600' });
            legend.textContent = payout ? 'Get paid to' : 'Pay with';
            picker.appendChild(legend);
            const options = cards.map((card) => [card.paymentMethodId, coinmeCardText(card)]);
            options.push(['new', { shown: 'Use a new card' }]);
            for (const [value, text] of options) {
                const label = element('label', null, {
                    display: 'flex',
                    alignItems: 'center',
                    gap: '10px',
                    boxSizing: 'border-box',
                    minHeight: '48px',
                    padding: '0 14px',
                    border: '1px solid ' + colors.line,
                    borderRadius: '10px',
                    background: '#fff',
                    cursor: 'pointer',
                });
                const radio = element('input', null, {
                    margin: '0',
                    width: '18px',
                    height: '18px',
                    accentColor: colors.focus,
                });
                radio.type = 'radio';
                radio.name = id + '-card';
                radio.value = value;
                if (text.spoken) radio.setAttribute('aria-label', text.spoken);
                radio.addEventListener('change', () => {
                    mark();
                    on.select(value);
                });
                label.append(radio, ' ' + text.shown);
                radios.push(radio);
                choices.push([radio, label]);
                picker.appendChild(label);
            }
            content.appendChild(picker);
        }

        const entries = Object.fromEntries(COINME_FORM.map((entry) => [entry.key, entry]));
        const inputs = {};
        const fields = {};
        const observers = [];
        const touched = new Set();
        let focusedInput = null;
        let secureStates = {};

        // VGS mounts each iframe at its own size; it is made to fill the field's box.
        const fit = (frame) => {
            if (typeof global.MutationObserver !== 'function') return;
            const observer = new global.MutationObserver(() => {
                frame.querySelectorAll('iframe').forEach((iframe) =>
                    coinmeStyled(iframe, {
                        display: 'block',
                        width: '100%',
                        height: '100%',
                        border: '0',
                    }),
                );
            });
            observer.observe(frame, { childList: true, subtree: true });
            observers.push(observer);
        };

        const filled = (key) =>
            key === 'state'
                ? /^[A-Za-z]{2}$/.test(inputs.state.value.trim())
                : inputs[key].value.trim() !== '';

        const paint = () => {
            for (const [key, field] of Object.entries(fields)) {
                let focused;
                let invalid;
                if (entries[key].vault) {
                    const state = isPlainObject(secureStates[key]) ? secureStates[key] : {};
                    focused = state.isFocused === true;
                    invalid = state.isTouched === true && state.isValid === false && !focused;
                } else {
                    focused = focusedInput === key;
                    invalid = touched.has(key) && !focused && !filled(key);
                }
                field.frame.style.borderColor = invalid
                    ? colors.error
                    : focused
                      ? colors.focus
                      : colors.line;
                field.frame.style.boxShadow = focused
                    ? '0 0 0 3px rgba(37, 99, 235, 0.15)'
                    : 'none';
                if (field.error) show(field.error, invalid, 'block');
            }
        };

        const field = (entry) => {
            const wrap = element(entry.vault ? 'div' : 'label', null, {
                display: 'grid',
                gap: '6px',
                alignContent: 'start',
                minWidth: '0',
            });
            const caption = element('span', null, { fontSize: '13px', color: colors.muted });
            caption.textContent = entry.label;
            let frame;
            if (entry.vault) {
                frame = element(
                    'div',
                    'meld-coinme-secure',
                    Object.assign({ overflow: 'hidden' }, box),
                );
                frame.id = id + '-' + entry.key;
                fit(frame);
            } else {
                frame = element(
                    'input',
                    null,
                    Object.assign(
                        { font: '16px ' + COINME_FONT, color: colors.text, outline: 'none' },
                        box,
                    ),
                );
                frame.name = entry.key;
                frame.type = 'text';
                frame.maxLength = entry.key === 'state' ? 2 : 64;
                frame.spellcheck = false;
                frame.setAttribute('autocomplete', entry.autocomplete);
                if (entry.placeholder) frame.placeholder = entry.placeholder;
                if (entry.key === 'state') frame.style.textTransform = 'uppercase';
                frame.addEventListener('input', () => on.refresh());
                frame.addEventListener('focus', () => {
                    focusedInput = entry.key;
                    paint();
                });
                frame.addEventListener('blur', () => {
                    focusedInput = null;
                    touched.add(entry.key);
                    paint();
                });
                inputs[entry.key] = frame;
            }
            wrap.append(caption, frame);
            let error = null;
            if (entry.error) {
                error = element('span', null, { fontSize: '12px', color: colors.error });
                error.textContent = entry.error;
                show(error, false, 'block');
                wrap.appendChild(error);
            }
            fields[entry.key] = { frame, error };
            return wrap;
        };

        const form = element('div', 'meld-coinme-form', { gap: '24px' });
        show(form, cards.length === 0, 'grid');
        for (const [title, rows] of COINME_LAYOUT) {
            const section = element('div', null, { display: 'grid', gap: '12px' });
            const heading = element('p', null, { margin: '0', fontWeight: '600' });
            heading.textContent = title;
            section.appendChild(heading);
            for (const keys of rows) {
                const row = element('div', null, {
                    display: 'grid',
                    gap: '12px',
                    gridTemplateColumns: COINME_COLUMNS[keys.length],
                });
                for (const key of keys) row.appendChild(field(entries[key]));
                section.appendChild(row);
            }
            form.appendChild(section);
        }
        content.appendChild(form);
        root.append(status, notice, content, pay);
        hostElement.appendChild(root);

        let closed = false;

        return {
            selector: (key) => '#' + id + '-' + key,
            progress(text) {
                if (closed) return;
                status.textContent = text;
                show(status, !!text, 'block');
            },
            notice(text) {
                if (closed) return;
                notice.textContent = text || '';
                show(notice, !!text, 'block');
            },
            /** The secure fields' state from the Vault, for their borders and error lines. */
            fields(states) {
                if (closed) return;
                secureStates = isPlainObject(states) ? states : {};
                paint();
            },
            /** A saved card's paymentMethodId, 'new', or null before the customer has chosen. */
            selected() {
                if (!radios.length) return 'new';
                const checked = radios.find((radio) => radio.checked);
                return checked ? checked.value : null;
            },
            showForm(visible) {
                show(form, visible, 'grid');
            },
            /** Back to the saved cards, none chosen. */
            unchoose() {
                radios.forEach((radio) => (radio.checked = false));
                mark();
                show(form, false, 'grid');
            },
            billing() {
                return coinmeBilling(inputs.state.value);
            },
            payable,
            lock(locked) {
                radios.forEach((radio) => (radio.disabled = locked));
                Object.values(inputs).forEach((input) => (input.disabled = locked));
                content.style.opacity = locked ? '0.6' : '1';
                if (locked) payable(false);
            },
            /** The outcome: the inputs go, the message stays until unmount. */
            end(text, failed) {
                if (closed) return;
                clearChildren(content);
                pay.remove();
                status.textContent = failed ? '' : text;
                show(status, !failed && !!text, 'block');
                notice.textContent = failed ? text : '';
                show(notice, !!failed && !!text, 'block');
            },
            close() {
                closed = true;
                observers.forEach((observer) => observer.disconnect());
                clearChildren(hostElement);
            },
        };
    }

    // ---- the flow

    function mountCoinmeCard(order, _details, hostElement, handlers) {
        const coinme = coinmeOrder(order);
        const orderId = order.id;
        const client = createActionClient(coinme.actions);
        let active = true;
        let ended = false;
        let busy = true;
        let paymentRequested = false;
        let browserToken = coinme.browserToken;
        let fingerprint = null;
        let webSessionId = null;
        let sdk = null;
        let vault = null;
        let opening = null;
        let unsubscribe = null;
        let pauseTimer = null;
        let loadTimer = null;
        const surface = coinmeSurface(hostElement, coinme.savedCards, coinme.payout, {
            select,
            pay,
            refresh,
        });
        surface.lock(true);
        surface.progress('Preparing checkout');

        function live() {
            return active && !ended;
        }

        function check() {
            if (!live()) throw coinmeError('cancelled');
        }

        /** Runs a step of a Coinme SDK; any failure of its own is a load failure named `detail`. */
        async function step(detail, work) {
            let value;
            try {
                value = await work();
            } catch (e) {
                check();
                throw coinmeError('load', { detail });
            }
            check();
            return value;
        }

        async function action(operation, fields, key) {
            check();
            try {
                const value = await client.send(operation, fields, key);
                check();
                return value;
            } catch (e) {
                check();
                throw e;
            }
        }

        function pause(ms) {
            return new Promise((resolve) => {
                pauseTimer = setTimeout(resolve, ms);
            }).then(check);
        }

        function vaultState() {
            try {
                const state = vault && vault.getFormState();
                return isPlainObject(state) ? state : null;
            } catch (e) {
                return null;
            }
        }

        function refresh() {
            if (!live() || busy) return;
            const choice = surface.selected();
            const state = vaultState();
            surface.fields(state && state.fields);
            surface.payable(
                choice === 'new'
                    ? !!(state && state.isValid === true && surface.billing())
                    : choice !== null,
            );
        }

        function disposeVault() {
            if (unsubscribe) {
                try {
                    unsubscribe();
                } catch (e) {
                    /* provider teardown must not throw into the SDK */
                }
            }
            unsubscribe = null;
            if (vault) {
                try {
                    vault.dispose();
                } catch (e) {
                    /* provider teardown must not throw into the SDK */
                }
            }
            vault = null;
        }

        function openForm() {
            if (!opening) {
                opening = step('load:vault', async () => {
                    const created = await sdk.createCoinmeVault({
                        environment: coinme.environment,
                    });
                    vault = created;
                    if (!live()) {
                        disposeVault();
                        return;
                    }
                    const names = sdk.VAULT_FIELD_NAMES;
                    for (const entry of COINME_FORM) {
                        if (!entry.vault) continue;
                        const options = Object.assign(
                            {
                                ariaLabel: entry.label,
                                iframeTitle: entry.label,
                                css: coinmeFieldCss(),
                            },
                            entry.options,
                        );
                        if (entry.vault === 'createTextField') options.name = names[entry.key];
                        created[entry.vault](surface.selector(entry.key), options);
                    }
                    unsubscribe = created.subscribe(refresh);
                });
            }
            return opening;
        }

        function riskFlow(flow) {
            return step('risk', () =>
                sdk.updateCoinmeRiskEngine({
                    customerId: coinme.customerId,
                    flow: sdk.FlowType[flow],
                }),
            );
        }

        async function boot() {
            fingerprint = uuid();
            sdk = await step('load:sdk', async () => coinmeSdk(await loadCoinmeSdk()));
            await step('load:risk', () =>
                sdk.setupCoinmeRiskEngine({
                    mode: coinme.environment === 'live' ? 'prod' : 'test',
                    clientId: coinme.riskClientId,
                    customerId: coinme.customerId,
                }),
            );
            const tag = await step('load:risk', () =>
                sdk.getSessionTag({
                    apiBaseUrl: COINME_RISK_API[coinme.environment],
                    fingerprint,
                    customerId: coinme.customerId,
                    additionalHeaders: {
                        partnerId: coinme.riskPartnerId,
                        'x-partner-id': coinme.riskPartnerId,
                    },
                }),
            );
            webSessionId = isPlainObject(tag) ? coinmeText(tag.webSessionID, COINME_TOKEN) : null;
            if (!webSessionId) throw coinmeError('load', { detail: 'load:risk' });
            if (!coinme.savedCards.length) await openForm();
        }

        async function refreshBrowserToken() {
            const response = await action('CREATE_CUSTOMER_AUTH_TOKEN', {}, uuid());
            const token = isPlainObject(response.sdk)
                ? coinmeText(response.sdk.clientSecret, COINME_TOKEN)
                : null;
            if (!token) throw coinmeError('invalidResponse');
            return token;
        }

        /** The browser token lasts ten minutes; an expired one is replaced, then submitted again. */
        async function submitCard(billing) {
            for (let refreshed = false; ; refreshed = true) {
                try {
                    const result = await sdk.submitPaymentMethod(vault, {
                        customerId: coinme.customerId,
                        paymentProcessAssociation: coinme.payout ? 'SELL' : 'BUY',
                        paymentProviderId: coinme.providerId,
                        webSessionId,
                        billingAddress: billing,
                        headers: {
                            'Content-Type': 'application/json',
                            Authorization: 'Bearer ' + browserToken,
                            'X-Device-Fingerprint': fingerprint,
                        },
                    });
                    check();
                    return result;
                } catch (e) {
                    check();
                    const status = coinmeVaultStatus(e);
                    if (refreshed || (status !== 401 && status !== 403)) throw e;
                }
                browserToken = await refreshBrowserToken();
            }
        }

        /** A card the customer already saved pays as that saved card, when it is clear which. */
        async function savedInstead() {
            const state = vaultState();
            const pan =
                state && isPlainObject(state.fields)
                    ? state.fields[sdk.VAULT_FIELD_NAMES.pan]
                    : null;
            const match = coinmeMatchingCard(pan, coinme.savedCards);
            if (match) {
                await riskFlow('CardTransaction');
                return match.paymentMethodId;
            }
            if (!coinme.savedCards.length) {
                throw coinmeError('card', { detail: 'vault:' + COINME_CARD_IN_USE });
            }
            surface.unchoose();
            surface.notice('This card is already saved. Choose it below.');
            return null;
        }

        /** The new card's paymentMethodId, or null when the customer has to act first. */
        async function newCard(billing) {
            await riskFlow('CardLinking');
            surface.progress('Adding your card');
            let result;
            try {
                result = await submitCard(billing);
            } catch (e) {
                // The token refresh's own failures, not the card's.
                if (e && (e.name === 'MeldPaymentActionError' || e.name === 'MeldCoinmeError')) {
                    throw e;
                }
                check();
                const code = coinmeVaultCode(e);
                if (code === COINME_CARD_IN_USE) return savedInstead();
                if (isPlainObject(e) && e.kind === 'validation') {
                    surface.notice('Check your card details.');
                    return null;
                }
                throw coinmeVaultFailure(e, code);
            }
            const body =
                isPlainObject(result) && isPlainObject(result.data) ? result.data.data : null;
            const added = isPlainObject(body) ? body.paymentMethod : null;
            const id = isPlainObject(added) ? coinmeText(added.paymentMethodId, COINME_ID) : null;
            if (!id) throw coinmeError('load', { detail: 'vault:invalidResponse' });
            return id;
        }

        /** A fresh key per request: the backend deduplicates by order, so no retry pays twice. */
        async function createPayment(paymentMethodId) {
            surface.progress(coinme.payout ? 'Saving your payout card' : 'Starting your payment');
            const started = Date.now();
            for (;;) {
                const key = uuid();
                paymentRequested = true;
                const response = await action(
                    'CREATE_PAYMENT_SESSION',
                    {
                        paymentToken: paymentMethodId,
                        riskSessionId: webSessionId,
                        deviceFingerprint: fingerprint,
                    },
                    key,
                );
                const state = response.status + '/' + response.nextStep;
                if (
                    state === 'SUBMITTED/WAIT_FOR_PROVIDER' ||
                    (coinme.payout && state === 'READY/WAIT_FOR_PAYMENT')
                ) {
                    finish();
                    surface.end(coinme.payout ? 'Payout card saved' : 'Payment submitted', false);
                    emit(handlers, 'onPaymentSubmitted', { orderId });
                    return;
                }
                if (state !== 'PENDING/RETRY') throw coinmeError('invalidResponse');
                if (Date.now() - started >= COINME_VERIFICATION_LIMIT_MS) {
                    throw coinmeError('verificationPending');
                }
                surface.progress('Verifying your card…');
                await pause(COINME_RETRY_PAUSE_MS);
            }
        }

        async function pay() {
            if (!live() || busy) return;
            const choice = surface.selected();
            const card = coinme.savedCards.find((saved) => saved.paymentMethodId === choice);
            const billing = choice === 'new' ? surface.billing() : null;
            const state = vaultState();
            if (!card && !(billing && state && state.isValid === true)) return;
            busy = true;
            surface.lock(true);
            surface.notice('');
            try {
                let paymentMethodId;
                if (card) {
                    await riskFlow('CardTransaction');
                    paymentMethodId = card.paymentMethodId;
                } else {
                    paymentMethodId = await newCard(billing);
                }
                if (paymentMethodId) {
                    await createPayment(paymentMethodId);
                    return;
                }
                busy = false;
                surface.progress('');
                surface.lock(false);
                refresh();
            } catch (e) {
                fail(e);
            }
        }

        function select(value) {
            if (!live() || busy) return;
            surface.notice('');
            surface.showForm(value === 'new');
            if (value === 'new') openForm().then(refresh, fail);
            refresh();
        }

        function fail(e) {
            if (!live() || !e || e.kind === 'cancelled') return;
            const [code, detail, message] = coinmeFailure(e, paymentRequested);
            const error = meldError(orderId, code, detail, message);
            // Nothing was paid, so mounting the same order again may work.
            if (code === ERROR_CODES.PROVIDER_LOAD_FAILED && !paymentRequested) {
                error.recoverable = true;
            }
            finish();
            surface.end(error.message, true);
            emit(handlers, 'onError', error);
        }

        /** No callback after this; the surface keeps its last message until unmount. */
        function finish() {
            ended = true;
            clearTimeout(pauseTimer);
            clearTimeout(loadTimer);
            client.close();
            disposeVault();
        }

        async function start() {
            if (!live()) return;
            try {
                await new Promise((resolve, reject) => {
                    loadTimer = setTimeout(
                        () => reject(coinmeError('load', { detail: 'load:timeout' })),
                        COINME_LOAD_TIMEOUT_MS,
                    );
                    boot().then(resolve, reject);
                });
            } catch (e) {
                fail(e);
                return;
            }
            clearTimeout(loadTimer);
            if (!live()) return;
            busy = false;
            surface.progress('');
            surface.lock(false);
            refresh();
            emit(handlers, 'onReady', { orderId });
        }

        setTimeout(start, 0);

        return {
            mode: 'embedded',
            unmount() {
                if (!active) return;
                finish();
                active = false;
                if (sdk) {
                    try {
                        sdk.clearSessionKey();
                    } catch (e) {
                        /* provider teardown must not throw into the SDK */
                    }
                }
                surface.close();
            },
        };
    }

    // ---------------------------------------------------------------- dispatch
    // The dispatch table, in registry form. First match wins; matching is on
    // (paymentMethodType, renderMode) — the discriminators the backend contract
    // guarantees — so a new provider is one registry entry + one mount function above.
    // Mercuryo cards only for now: future adapters slot in as new entries before the
    // 'unsupported' fallthrough.

    const ADAPTERS = [
        {
            name: 'coinbase-apple-pay-iframe',
            presentation: {
                paymentMethodType: 'APPLE_PAY',
                surface: 'PROVIDER_HOSTED',
                protocol: 'COINBASE_APPLE_PAY',
                version: 1,
            },
            label: 'Coinbase Apple Pay (APPLE_PAY / PROVIDER_HOSTED)',
            offered: () => coinbaseOffered,
            matches: () => false,
            admissionError: coinbaseAdmissionError,
            // The customer presses Coinbase's own button inside the frame; nothing can press it for them.
            capabilities: { embeddable: true, surface: 'embedded', requiresUserGesture: true },
            // No readiness check: outside Safari the page shows a QR code that still pays the order.
            mount: mountCoinbaseApplePay,
        },
        {
            name: 'stripe-crypto-onramp-card',
            presentation: {
                paymentMethodType: 'CREDIT_DEBIT_CARD',
                surface: 'NATIVE_SDK',
                protocol: 'STRIPE_CRYPTO_ONRAMP',
                version: 1,
            },
            label: 'Stripe card (CREDIT_DEBIT_CARD / NATIVE_SDK)',
            offered: () => stripeOffered,
            matches: () => false,
            admissionError: stripeAdmissionError,
            capabilities: { embeddable: true, surface: 'embedded', requiresUserGesture: false },
            mount: mountStripe,
        },
        {
            name: 'stripe-crypto-onramp-apple-pay',
            presentation: {
                paymentMethodType: 'APPLE_PAY',
                surface: 'NATIVE_SDK',
                protocol: 'STRIPE_CRYPTO_ONRAMP',
                version: 1,
            },
            label: 'Stripe Apple Pay (APPLE_PAY / NATIVE_SDK)',
            offered: () => stripeOffered,
            matches: () => false,
            admissionError: stripeAdmissionError,
            capabilities: { embeddable: true, surface: 'embedded', requiresUserGesture: true },
            // The mount ends with PAYMENT_METHOD_UNAVAILABLE where the browser has no Apple Pay.
            readiness: deviceReadiness,
            mount: mountStripe,
        },
        {
            name: 'uphold-card-iframe',
            presentation: {
                paymentMethodType: 'CREDIT_DEBIT_CARD',
                surface: 'EMBEDDED_WIDGET',
                protocol: 'UPHOLD_WIDGET',
                version: 1,
            },
            // Uphold card is ALSO (CREDIT_DEBIT_CARD / IFRAME) — same discriminators as
            // Mercuryo — so this entry is host-gated and registered FIRST: Uphold-hosted
            // orders match here; Mercuryo legacy orders must match their own registered host.
            label: 'Uphold card (CREDIT_DEBIT_CARD / IFRAME)',
            matches: (type, details) =>
                type === 'CREDIT_DEBIT_CARD' &&
                details.renderMode === 'IFRAME' &&
                isUpholdHost(details.serviceProviderWidgetUrl),
            capabilities: { embeddable: true, surface: 'embedded', requiresUserGesture: false },
            mount: mountUpholdCard,
        },
        {
            name: 'banxa-card-sdk',
            presentation: {
                paymentMethodType: 'CREDIT_DEBIT_CARD',
                // VENDOR_SDK, not EMBEDDED_WIDGET: surface names what the PROVIDER exposes, and this
                // mounts Banxa's own checkout from an SDK token. Matches the catalog declaration.
                surface: 'VENDOR_SDK',
                protocol: 'BANXA_CHECKOUT',
                version: 1,
            },
            // Banxa is ALSO (CREDIT_DEBIT_CARD / IFRAME) and carries NO widget URL, so it cannot be
            // host-gated the way Uphold is — it selects on the provider itself and is registered
            // independently of URL-based legacy adapters, which cannot recognize its missing
            // serviceProviderWidgetUrl.
            label: 'Banxa card (CREDIT_DEBIT_CARD / IFRAME, SDK token)',
            matches: (type, details, order) =>
                type === 'CREDIT_DEBIT_CARD' &&
                details.renderMode === 'IFRAME' &&
                serviceProviderOf(order) === 'BANXA',
            capabilities: { embeddable: true, surface: 'embedded', requiresUserGesture: false },
            mount: mountBanxaCheckout,
        },
        {
            name: 'banxa-apple-pay-sdk',
            presentation: {
                paymentMethodType: 'APPLE_PAY',
                surface: 'VENDOR_SDK',
                protocol: 'BANXA_CHECKOUT',
                version: 1,
            },
            label: 'Banxa Apple Pay (APPLE_PAY / provider SDK)',
            // Legacy selection when no headlessPresentation exists: VENDOR_SDK says "a vendor's own SDK presents the
            // sheet from sdkSessionToken", which is the shape this adapter handles. serviceProvider is
            // still checked because the token is fed to Banxa's component specifically — a second
            // VENDOR_SDK provider would need its own entry, and silently handing it Banxa's component
            // would be worse than not matching.
            //
            // VENDOR_SDK is the value the backend actually emits (a wallet order's presentation is
            // NATIVE_TOKEN | VENDOR_SDK | PROVIDER_HOSTED, serialised by name), and it is what the iOS
            // SDK parses. This matched PROVIDER_SDK, a name that appears nowhere on the wire, so every
            // real Banxa Apple Pay order fell through to `unsupported`: capabilities reported
            // embeddable:false and mount threw "No embeddable adapter". The tests agreed only because
            // their fixtures invented the same value.
            matches: (type, details, order) =>
                type === 'APPLE_PAY' &&
                details.presentation === 'VENDOR_SDK' &&
                serviceProviderOf(order) === 'BANXA',
            // requiresUserGesture: the sheet opens from a tap on the component's own Apple Pay
            // button, inside the frame holding the merchant session — Apple requires the gesture
            // there. A host must not render a competing button in front of it.
            capabilities: { embeddable: true, surface: 'embedded', requiresUserGesture: true },
            mount: mountBanxaCheckout,
        },
        {
            name: 'coinme-card-vault',
            presentation: {
                paymentMethodType: 'CREDIT_DEBIT_CARD',
                surface: 'VENDOR_SDK',
                protocol: 'COINME_VAULT',
                version: 1,
            },
            label: 'Coinme card (CREDIT_DEBIT_CARD / VENDOR_SDK)',
            matches: () => false,
            admissionError: coinmeAdmissionError,
            capabilities: { embeddable: true, surface: 'embedded', requiresUserGesture: false },
            mount: mountCoinmeCard,
        },
        {
            name: 'mercuryo-card-iframe',
            presentation: {
                paymentMethodType: 'CREDIT_DEBIT_CARD',
                surface: 'EMBEDDED_WIDGET',
                protocol: 'MERCURYO_WIDGET',
                version: 1,
            },
            // Human-readable (paymentMethodType / renderMode) this adapter handles. Used to
            // build the "unsupported order" error so it stays truthful as adapters are added.
            label: 'Mercuryo card (CREDIT_DEBIT_CARD / IFRAME)',
            matches: (type, details) =>
                type === 'CREDIT_DEBIT_CARD' &&
                details.renderMode === 'IFRAME' &&
                isRegisteredWidgetUrl('MERCURYO', details.serviceProviderWidgetUrl),
            capabilities: { embeddable: true, surface: 'embedded', requiresUserGesture: false },
            mount: mountMercuryoCard,
        },
        {
            name: 'unsupported',
            // fallthrough: APPLE_PAY, non-IFRAME cards, bank transfers, …
            matches: () => true,
            capabilities: { embeddable: false, surface: 'unsupported', requiresUserGesture: false },
            mount: (order, details) => {
                const supported = offeredAdapters()
                    .filter((a) => a.label)
                    .map((a) => a.label)
                    .join(', ');
                throw new Error(
                    'No embeddable adapter for paymentMethodType=' +
                        order.paymentMethodType +
                        (details.renderMode ? ' renderMode=' + details.renderMode : '') +
                        '. This SDK supports: ' +
                        supported +
                        '. Guard with Meld.capabilities(order).embeddable before calling mount().',
                );
            },
        },
    ];

    /** The adapters this release presents. One whose prerequisites are not live yet is left out. */
    function offeredAdapters() {
        return ADAPTERS.filter((adapter) => !adapter.offered || adapter.offered());
    }

    function presentationAdapter(presentation, paymentMethodType) {
        if (!presentation || typeof presentation !== 'object' || Array.isArray(presentation)) {
            return null;
        }
        return offeredAdapters().find((adapter) => {
            const declared = adapter.presentation;
            return (
                declared &&
                declared.paymentMethodType === paymentMethodType &&
                declared.surface === presentation.surface &&
                declared.protocol === presentation.protocol &&
                declared.version === presentation.version
            );
        });
    }

    function resolveAdapter(order) {
        const details = order?.paymentMethodResponseDetails || {};
        const unsupported = ADAPTERS.find((adapter) => adapter.name === 'unsupported');
        // A declaration is authoritative, including null/malformed/unknown declarations.
        // Only responses with no declaration may use adapter-owned legacy signatures.
        const adapter =
            order && Object.prototype.hasOwnProperty.call(order, 'headlessPresentation')
                ? presentationAdapter(order.headlessPresentation, order.paymentMethodType)
                : offeredAdapters().find((candidate) =>
                      candidate.matches(order?.paymentMethodType, details, order),
                  );
        const declined =
            adapter && adapter.admissionError && adapter.admissionError(order, details);
        if (declined) {
            console.warn(
                '[meld-sdk] ' + adapter.label + ' cannot present this order: ' + declined + '.',
            );
            return { adapter: unsupported, details };
        }
        return { adapter: adapter || unsupported, details };
    }

    /** Advisory pre-create discovery only; an actual order must still pass capabilities/mount. */
    function presentationCapabilities(presentation, paymentMethodType) {
        const adapter =
            presentationAdapter(presentation, paymentMethodType) ||
            ADAPTERS.find((candidate) => candidate.name === 'unsupported');
        return Object.assign({}, adapter.capabilities);
    }

    // --------------------------------------------------------------- readiness
    // Whether this browser can pay with a method, asked before an order exists. The answers are the
    // native SDKs': ready, unavailable (always PAYMENT_METHOD_UNAVAILABLE) or unknown.

    /** ApplePaySession.canMakePayments(), or false where this page cannot ask. */
    function applePayAvailable() {
        try {
            const session = global.ApplePaySession;
            return (
                typeof session === 'function' &&
                typeof session.canMakePayments === 'function' &&
                session.canMakePayments() === true
            );
        } catch (e) {
            return false;
        }
    }

    function unavailableReadiness(reason) {
        return { status: 'unavailable', code: ERROR_CODES.PAYMENT_METHOD_UNAVAILABLE, reason };
    }

    /** The answer for a method this SDK presents without asking the browser anything. */
    function uncheckedReadiness() {
        return {
            status: 'unknown',
            reason: 'This payment method has no device check; offer it and let the payment decide.',
        };
    }

    function deviceReadiness(paymentMethodType) {
        switch (paymentMethodType) {
            case 'APPLE_PAY':
                return applePayAvailable()
                    ? { status: 'ready' }
                    : unavailableReadiness('Apple Pay has no usable card on this device.');
            case 'GOOGLE_PAY':
                return unavailableReadiness('Google Pay is not available on the web.');
            default:
                return uncheckedReadiness();
        }
    }

    /** Never rejects: a check that throws is unknown. */
    function answerReadiness(ask) {
        try {
            return Promise.resolve(ask());
        } catch (e) {
            return Promise.resolve({ status: 'unknown', reason: 'The readiness check failed.' });
        }
    }

    function paymentMethodReadiness(paymentMethodType) {
        return answerReadiness(() => deviceReadiness(paymentMethodType));
    }

    function describeRow(method, presentation) {
        if (!isPlainObject(presentation)) return method + ' without a headlessPresentation';
        const p = presentation;
        return method + ' via ' + p.surface + '/' + p.protocol + ' v' + p.version;
    }

    /** A quote row's paymentMethodType and headlessPresentation, as presentationAdapter reads them. */
    function rowReadiness(row) {
        if (!isPlainObject(row)) {
            return unavailableReadiness('The row is not a quote row.');
        }
        const method = row.paymentMethodType;
        const adapter = presentationAdapter(row.headlessPresentation, method);
        if (!adapter) {
            const asked = describeRow(method, row.headlessPresentation);
            return unavailableReadiness('This SDK does not present ' + asked + '.');
        }
        return adapter.readiness ? adapter.readiness(method) : uncheckedReadiness();
    }

    function presentationReadiness(row) {
        return answerReadiness(() => rowReadiness(row));
    }

    // -------------------------------------------------------------- public API

    function mount(order, hostElement, handlers) {
        if (!order || !order.paymentMethodType) {
            throw new Error('mount() requires the order from POST /crypto/order/headless/onramp');
        }
        if (!(hostElement instanceof Element)) {
            throw new Error('mount() requires a DOM element to mount into');
        }
        // A prior mount still active? Tear it down first so its window 'message' listener + iframe don't
        // leak when the integrator calls mount() again without an explicit unmount().
        if (activeSession && typeof activeSession.unmount === 'function') {
            try {
                activeSession.unmount();
            } catch (e) {
                /* best-effort teardown */
            }
        }
        const { adapter, details } = resolveAdapter(order);
        activeSession = adapter.mount(
            order,
            details,
            hostElement,
            gateTerminalEvents(nameErrorPaymentMethod(handlers || {}, order.paymentMethodType)),
        );
        return activeSession;
    }

    function capabilities(order) {
        return Object.assign({}, resolveAdapter(order).adapter.capabilities);
    }

    /**
     * CSP directives the integrator's payment page needs per enabled provider —
     * frame-src/script-src origins and the iframe `allow` permissions. Every value is
     * read from the provider registry, so this carries no provider-specific knowledge
     * and integrators don't reverse-engineer provider hosts or permissions.
     */
    function requiredCsp(providers) {
        const frameSrc = [];
        const scriptSrc = [];
        const connectSrc = [];
        const imgSrc = [];
        const iframeAllow = [];
        (providers || []).forEach((p) => {
            const hosts = PROVIDER_HOSTS[p] && PROVIDER_HOSTS[p][providerEnvironment()];
            if (hosts) {
                frameSrc.push(...hosts.frameSrc);
                if (hosts.scriptSrc) {
                    scriptSrc.push(...[].concat(hosts.scriptSrc));
                }
                if (hosts.connectSrc) connectSrc.push(...hosts.connectSrc);
                if (hosts.imgSrc) imgSrc.push(...hosts.imgSrc);
                const actionBase = ACTION_API_BASES[config.environment || 'sandbox'];
                if (hosts.paymentActions && actionBase && !config.actionProxyUrl) {
                    connectSrc.push(actionBase);
                }
                // A dynamic import() is governed by script-src just as a <script> tag is, so a
                // provider loaded as an ES module (Banxa) must land here too — otherwise
                // requiredCsp() emits a policy that silently blocks the payment surface it was
                // generated for.
                if (hosts.moduleSrc) {
                    // The ORIGIN, not the file URL: a path-qualified script-src matches only that
                    // path prefix, and the module's first line is a transitive
                    // `import ... from "/npm/@primer-io/primer-js@.../+esm"` on the same CDN — a
                    // policy naming only our file blocks Primer and kills the checkout for exactly
                    // the integrators who deployed the CSP we told them to.
                    scriptSrc.push(new URL(hosts.moduleSrc).origin);
                }
                if (hosts.iframeAllow) {
                    iframeAllow.push(...hosts.iframeAllow);
                }
            }
        });
        // De-dupe so providers sharing a host or permission don't emit it twice.
        return {
            frameSrc: [...new Set(frameSrc)],
            scriptSrc: [...new Set(scriptSrc)],
            connectSrc: [...new Set(connectSrc)],
            imgSrc: [...new Set(imgSrc)],
            iframeAllow: [...new Set(iframeAllow)],
        };
    }

    const Meld = {
        configure,
        mount,
        capabilities,
        presentationCapabilities,
        paymentMethodReadiness,
        presentationReadiness,
        requiredCsp,
        attemptMayExist,
        ErrorCode: ERROR_CODES,
    };

    // Test-only seam, deliberately not in index.d.ts and not part of the public contract. Node cannot
    // import an https URL, so the Banxa module never resolves under test and every line after the
    // import would otherwise be dead to the suite.
    Object.defineProperty(Meld, '__setBanxaModuleLoader', {
        enumerable: false,
        value: function (loader) {
            loadBanxaModule = loader;
        },
    });

    // Test-only, like the Banxa seam. null restores Stripe's own loader.
    Object.defineProperty(Meld, '__setStripeRuntimeLoader', {
        enumerable: false,
        value: function (loader) {
            loadStripeRuntime = loader || defaultStripeRuntimeLoader;
        },
    });

    // Test-only, like the Banxa seam: shortens the Stripe flow's waits. null restores them.
    Object.defineProperty(Meld, '__setStripeTimings', {
        enumerable: false,
        value: function (timings) {
            stripeTimings = Object.freeze(Object.assign({}, STRIPE_TIMINGS, timings || {}));
        },
    });

    // Test-only, like the Banxa seam: replaces the vendored Coinme SDKs. null restores them.
    Object.defineProperty(Meld, '__setCoinmeSdkLoader', {
        enumerable: false,
        value: function (loader) {
            loadCoinmeSdk = loader || defaultCoinmeSdkLoader;
        },
    });

    // Test-only, like the Banxa seam: offers the adapters this release withholds, so their suites run.
    Object.defineProperty(Meld, '__setCoinbaseOffered', {
        enumerable: false,
        value: function (offered) {
            coinbaseOffered = offered === true;
        },
    });

    Object.defineProperty(Meld, '__setStripeOffered', {
        enumerable: false,
        value: function (offered) {
            stripeOffered = offered === true;
        },
    });

    // Test-only, like the Banxa seam: the transport has no public entry point of its own.
    Object.defineProperty(Meld, '__paymentActions', {
        enumerable: false,
        value: Object.freeze({ descriptor: paymentActionDescriptor, client: createActionClient }),
    });

    // Replaces fetch for payment actions; null restores it. Not public: tests use it, and so do Meld's iOS
    // and Android SDKs, which run this bundle in a WebView and send each action over their native bridge.
    Object.defineProperty(Meld, '__setActionTransport', {
        enumerable: false,
        value: function (transport) {
            actionTransportOverride = transport || null;
        },
    });

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = Meld;
    }
    global.Meld = Meld;
})(typeof window !== 'undefined' ? window : globalThis);
