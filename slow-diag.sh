#!/bin/bash
# slow-diag.sh v1.1 | Levamo/Rapyd | diagnostico read-only de avisos "Slow response" del monitor
# uso: slow-diag.sh <dominio|slug> [--hours 12] [--samples 5] [--thr 2] [--no-db] [--php-probe]
#      slow-diag.sh --all [--thr 2]     tabla de una linea por cada site del nodo
# etiquetas: CONF medido/leido en esta corrida | IND indicio, falta 2do angulo | BUG defecto de plataforma
#            SD sin datos | INFO contexto | OK revisado sin hallazgo
# No cambia nada. --php-probe deja un .php temporal en el webroot para UN request y lo borra.
# salida: $OUTDIR/slow-diag-<slug>-<utc>.txt y $OUTDIR/slow-diag-<slug>.findings (para slow-fix.sh)
export LC_ALL=C TZ=UTC
CONF=${CONF:-/var/www/conf}; HOMEB=${HOMEB:-/home}; SLOG=${SLOG:-/var/www/logs}; OUTDIR=${OUTDIR:-/root}
RSM=${RSM:-/etc/rapyd-rsm/rapyd-rsm.conf}; RT=${RT:-/dev/shm/ols/status/.rtreport}; LB=${LB:-127.0.0.1}
HOURS=12; SAMPLES=5; THR=2; NODB=0; PROBE=0; ALL=0; TGT=
while [ $# -gt 0 ]; do case $1 in
  --hours) HOURS=$2; shift;; --samples) SAMPLES=$2; shift;; --thr) THR=$2; shift;;
  --no-db) NODB=1;; --php-probe) PROBE=1;; --all) ALL=1;;
  -h|--help) sed -n '2,8p' "$0"; exit 0;; -*) echo "opcion desconocida: $1"; exit 1;; *) TGT=$1;; esac; shift; done
HC=$CONF/httpd_config.conf
MUA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3 rapyd-cloud-uptime/1.0 (Rapyd Monitor 1.0)'
BUA='Mozilla/5.0 (X11; Linux x86_64) slow-diag/1.1'; IDLE=${IDLE:-360}
AWK=$(command -v gawk || command -v awk); GAWK=0; "$AWK" --version 2>/dev/null | grep -q GNU && GAWK=1
TMPD=$(mktemp -d); PF=; trap 'rm -rf "$TMPD"; [ -n "$PF" ] && rm -f "$PF"' EXIT
FIND=()
say(){ printf '  %-5s %s\n' "$1" "$2"; }
fnd(){ say "$1" "[$2] $4"; FIND+=("$1|$2|$3|$4"); }   # etiqueta codigo clase texto
hdr(){ printf '\n== %s\n' "$1"; }
ge(){ awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }
num(){ [[ $1 =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }

# --- mapeo dominio <-> slug (httpd_config.conf: map <vhost> <dominios>, virtualhost -> vhRoot)
vh_of_dom(){ awk -v d="$1" '$1=="map"{for(i=3;i<=NF;i++){x=$i;gsub(/,/,"",x);if(x==d){print $2;exit}}}' "$HC"; }
root_of_vh(){ awk -v v="$1" '$1=="virtualhost"&&$2==v{f=1} f&&$1=="vhRoot"{print $2;exit}' "$HC"; }
doms_of_slug(){ awk -v r="$HOMEB/web_$1/web" '
  $1=="virtualhost"{v=$2} $1=="vhRoot"{x=$2;sub(/\/$/,"",x);if(x==r)ok[v]=1}
  $1=="map"{for(i=3;i<=NF;i++){d=$i;gsub(/,/,"",d);if(d!="*")m[$2]=m[$2]" "d}}
  END{for(v in ok)print m[v]}' "$HC" | tr ' ' '\n' | grep -v '^$' | sort -u; }

hv(){ local v; v=$(grep -i "^$1:" "$TMPD/h" 2>/dev/null | tail -1 | cut -d: -f2- | tr -d '\r '); echo "${v:--}"; }
# probe <url> <ua> <lb|cf> -> "code ttfb total bytes lsc cfcache bypass"
probe(){ local r ca=(-s -o /dev/null -D "$TMPD/h" --max-time 60 -A "$2")
  [ "$3" = lb ] && ca+=(-k --resolve "$DOM:443:$LB"); [ "$4" = L ] && ca+=(-L)
  : > "$TMPD/h"; r=$(curl "${ca[@]}" -w '%{http_code} %{time_starttransfer} %{time_total} %{size_download} %{num_redirects}' "$1" 2>/dev/null)
  r=$(echo "${r:-000 0 0 0 0}" | awk '{printf "%s %.3f %.3f %s %d",$1,$2,$3,$4,$5}'); local x1 x2 x3 x4 x5; read -r x1 x2 x3 x4 x5 <<<"$r"
  echo "$x1 $x2 $x3 $x4 $(hv x-litespeed-cache) $(hv cf-cache-status) $(hv x-rapyd-bypass-reason) $x5"; }
# series <nombre> <url> <ua> <lb|cf> <n> <bust 0|1> [L = seguir redirects]
series(){ local i u o; : > "$TMPD/s_$1"
  for i in $(seq "$5"); do u=$2; [ "$6" = 1 ] && u="$2?rCache=$(date +%s%3N)"
    o=$(probe "$u" "$3" "$4" "$7"); echo "$o" >> "$TMPD/s_$1"
    read -r c t tt b l cf by rd <<<"$o"
    printf '        %-7s #%d code=%s ttfb=%ss total=%ss %sB lsc=%s cf=%s bypass=%s redir=%s\n' "$1" "$i" "$c" "$t" "$tt" "$b" "$l" "$cf" "$by" "$rd"
  done; }
st3(){ awk -v c="${2:-2}" '{print $c}' "$TMPD/s_$1" | sort -n | awk '{a[NR]=$1} END{if(NR)print a[1],a[int((NR+1)/2)],a[NR]; else print "0 0 0"}'; }
hits(){ awk 'NR>1 && tolower($5)~/hit/' "$TMPD/s_$1" | wc -l; }
vkey(){ awk -v k="$(echo "$1" | tr 'A-Z' 'a-z')" 'tolower($1)==k{print $2;exit}' "$2" 2>/dev/null; }
venv(){ grep -oiE "$1=-?[0-9]+" "$2" 2>/dev/null | head -1 | cut -d= -f2; }

# ================= modo --all
if [ "$ALL" = 1 ]; then
  printf '%-22s %-4s %-5s %-5s %-6s %-5s %-34s %-14s %-14s\n' slug inst maxc child cache procs dominio busted home2
  for vc in "$HOMEB"/web_*/web/conf/vhconf.conf; do
    s=${vc#"$HOMEB"/web_}; s=${s%%/web/conf/vhconf.conf}
    DOM=$(doms_of_slug "$s" | grep -v rapydapps | head -1); [ -z "$DOM" ] && DOM=$(doms_of_slug "$s" | head -1)
    cfl=$(grep -iE '^\s*(enableCache|ls_enabled)' "$vc" | awk '{print $2}' | tr '\n' '/' | sed 's#/$##')
    np=$(pgrep -u "web_$s" -f lsphp 2>/dev/null | wc -l)
    B=-; H=-
    if [ -n "$DOM" ]; then
      read -r c t _ _ l _ <<<"$(probe "https://$DOM/?rCache=$(date +%s%3N)" "$MUA" lb)"; B="$c/${t}s/$l"
      probe "https://$DOM/" "$BUA" lb >/dev/null
      read -r c t _ _ l _ <<<"$(probe "https://$DOM/" "$BUA" lb)"; H="$c/${t}s/$l"
    fi
    printf '%-22s %-4s %-5s %-5s %-6s %-5s %-34s %-14s %-14s\n' "$s" "$(vkey instances "$vc")" "$(vkey maxConns "$vc")" \
      "$(venv PHP_LSAPI_CHILDREN "$vc")" "${cfl:--}" "$np" "${DOM:--}" "$B" "$H"
  done
  echo "busted = / con ?rCache y UA del monitor (como sondea el monitor); home2 = / normal, segunda pasada (cache caliente)"
  echo "code/ttfb/x-litespeed-cache; una sola muestra por site: indicio, no medicion"
  exit 0
fi

# ================= resolucion del objetivo
[ -z "$TGT" ] && { sed -n '2,8p' "$0"; exit 1; }
[ -r "$HC" ] || { echo "no se puede leer $HC"; exit 1; }
SLUG=; DOM=
if [ -d "$HOMEB/web_$TGT" ]; then SLUG=$TGT
else DOM=$TGT; VH=$(vh_of_dom "$DOM"); R=$(root_of_vh "$VH")
  SLUG=$(echo "$R" | sed -n "s#^$HOMEB/web_\([^/]*\)/web/*\$#\1#p")
  [ -z "$SLUG" ] && { s=$(echo "$DOM" | sed -n 's/^\(.*\)-rpd-[a-z0-9]*\..*/\1/p'); [ -n "$s" ] && [ -d "$HOMEB/web_$s" ] && SLUG=$s; }
fi
if [ -z "$SLUG" ] || [ ! -d "$HOMEB/web_$SLUG" ]; then
  echo "'$TGT' no mapea a ningun site de $(hostname)."
  d=$(echo "$TGT" | grep -oE 'rpd-[a-z0-9]+'); n=$(hostname | grep -oE 'rpd-[a-z0-9]+')
  [ -n "$d" ] && [ "$d" != "$n" ] && echo "El dominio es de $d y este nodo es $n: correr en el nodo correcto."
  echo "Verificar: grep -n \"$TGT\" $HC ; rapyd site list"; exit 1
fi
ALLD=$(doms_of_slug "$SLUG")
[ -z "$DOM" ] && { DOM=$(echo "$ALLD" | grep -v rapydapps | head -1); [ -z "$DOM" ] && DOM=$(echo "$ALLD" | head -1); }
SB=$HOMEB/web_$SLUG/web; VC=$SB/conf/vhconf.conf; LOGD=$SB/logs; PHPD=$SB/php; U=web_$SLUG
WR=$SB/www/app/public
[ -f "$WR/wp-config.php" ] || { w=$(find "$SB/www" -maxdepth 4 -name wp-config.php 2>/dev/null | head -1); [ -n "$w" ] && WR=$(dirname "$w"); }
NOW=$(date +%s); SINCE=$((NOW - HOURS*3600)); SINCES=$(date -u -d "@$SINCE" '+%F %T')
OUT=$OUTDIR/slow-diag-$SLUG-$(date -u +%Y%m%d-%H%M).txt
exec > >(tee "$OUT") 2>&1

# ================= 1 objetivo y nodo
hdr "1 objetivo"
say INFO "nodo=$(hostname) ahora=$(date -u '+%F %T') UTC ventana=${HOURS}h (desde $SINCES) umbral=${THR}s"
say INFO "dominio=$DOM slug=$SLUG usuario=$U webroot=$WR"
say INFO "dominios del site: $(echo "$ALLD" | tr '\n' ' ')"
RS=$(rapyd site list 2>/dev/null | grep -w -- "$SLUG" | head -2 | tr -s ' ' | cut -c1-200)
[ -n "$RS" ] && say INFO "rapyd site list: $RS"
say INFO "carga: $(cut -d' ' -f1-3 /proc/loadavg) nproc=$(nproc) uptime=$(uptime -p 2>/dev/null)"

# ================= 2 medicion en vivo (loopback, sin Cloudflare) + via Cloudflare
hdr "2 medicion en vivo ($SAMPLES muestras, loopback $LB con SNI $DOM)"
PB=$(pgrep -u "$U" -f lsphp 2>/dev/null | wc -l); PO=$(ps -u "$U" -o etimes=,args= 2>/dev/null | grep '[l]sphp' | sort -rn | awk 'NR==1{print $1}')
say INFO "pool lsphp antes de medir: $PB procesos${PO:+, el mas viejo ${PO}s}"
say INFO "monitor = / con ?rCache y UA del monitor, siguiendo redirects (total = cadena completa):"
series monitor "https://$DOM/" "$MUA" lb "$SAMPLES" 1 L
series static "https://$DOM/wp-includes/js/jquery/jquery.min.js" "$BUA" lb "$SAMPLES" 0
series home "https://$DOM/" "$BUA" lb "$SAMPLES" 0
series busted "https://$DOM/" "$MUA" lb "$SAMPLES" 1
say INFO "via Cloudflare (IP publica, URL y UA del monitor):"
series cf "https://$DOM/" "$MUA" cf 3 1
read -r _ SMED _ <<<"$(st3 static)"; read -r _ HMED _ <<<"$(st3 home)"; read -r BMIN BMED BMAX <<<"$(st3 busted)"
read -r _ CMED _ <<<"$(st3 cf)"; read -r MMIN MMED MMAX <<<"$(st3 monitor 3)"
M1=$(awk 'NR==1{print $3}' "$TMPD/s_monitor"); MRD=$(awk '{print $8}' "$TMPD/s_monitor" | sort -u | tr '\n' ' ')
HC0=$(awk '{print $1}' "$TMPD/s_home" | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
BC0=$(awk '{print $1}' "$TMPD/s_busted" | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
HH=$(hits home); BH=$(awk 'tolower($5)~/hit/' "$TMPD/s_busted" | wc -l); BYP=$(awk '$7!="-"{print $7}' "$TMPD/s_home" | sort -u | tr '\n' ' ')
say INFO "monitor 1ra=${M1}s min/med/max=${MMIN}/${MMED}/${MMAX}s redirects=${MRD}"
say INFO "static med=${SMED}s | home med=${HMED}s hits=$HH/$((SAMPLES-1)) | busted min/med/max=${BMIN}/${BMED}/${BMAX}s | cf med=${CMED}s"
if [ "$HC0" = 000 ]; then fnd SD LOOPBACK CHECK "loopback a $LB:443 no respondio (code 000): seccion 2 sin datos"
else
  case $HC0 in 30[1278]) say INFO "home responde $HC0 -> $(curl -sk -o /dev/null -w '%{redirect_url}' --resolve "$DOM:443:$LB" "https://$DOM/")";; esac
  case $BC0 in 401|403) fnd IND ORIGIN_DENIES CHECK "origen responde $BC0 a la URL del monitor: el monitor estaria midiendo una pagina de error/auth (staging?)";; esac
  ge "$SMED" 1 && fnd IND STATIC_SLOW CHECK "un .js estatico tarda ${SMED}s por loopback: problema a nivel nodo/LiteSpeed (carga, cola, disco), no PHP"
  [ "$PB" = 0 ] && [ "$SAMPLES" -gt 1 ] && ge "$M1" "$THR" && ge "$M1" "$(awk -v m="$MMED" 'BEGIN{print m*2}')" && \
    fnd CONF COLD_START CHECK "pool sin procesos antes de medir: 1ra sonda ${M1}s, mediana ${MMED}s (arranque en frio, esta medicion)"
  ge "$MMED" "$THR" && fnd CONF MONITOR_CHAIN_SLOW CHECK "la cadena del monitor (redirects=${MRD% }) tarda mediana ${MMED}s con el pool caliente (esta medicion)"
  [ "$HC0" = 200 ] && [ "$HH" = 0 ] && [ "$SAMPLES" -gt 1 ] && fnd CONF CACHE_NO_HIT FIX-OK "la home no dio HIT en ninguna repeticion (bypass: ${BYP:--}); ver seccion 4 cache y seccion 6 LSCWP"
  [ "$BH" -gt 0 ] && say INFO "la URL con ?rCache se sirvio desde cache $BH veces (drop_qs activo o similar)"
  if ge "$BMED" "$THR"; then
    fnd CONF GEN_SLOW CHECK "generacion sin cache mediana ${BMED}s (max ${BMAX}s) en $SAMPLES muestras AHORA; vale para esta medicion, no para la ventana del aviso"
    [ "$HC0" = 200 ] && [ "$HH" -gt 0 ] && ! ge "$HMED" 1 && fnd CONF MONITOR_BUSTS_CACHE PLAT "?rCache da MISS y la home normal da HIT en ${HMED}s: el monitor mide generacion PHP sin cache, no lo que ve un visitante"
  else say OK "generacion sin cache ${BMED}s < ${THR}s en este momento"; fi
fi

# ================= 3 access log: sondas del monitor, orden de escritura, trafico
hdr "3 access log (ultimas ${HOURS}h)"
ALF=$(find "$LOGD" -maxdepth 1 -name 'access.log*' -mmin -$((HOURS*60+60)) -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}')
LL=$(tail -n 1 "$LOGD/access.log" 2>/dev/null)
say INFO "archivos: $(echo "$ALF" | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
say INFO "ultima linea: $(echo "$LL" | cut -c1-220)"
FMT='^[^ ]+ .*\[[0-9]{2}/[A-Z][a-z]{2}/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}\] "[^"]*" [0-9]{3} '
if [ -z "$ALF" ] || ! echo "$LL" | grep -qE "$FMT"; then fnd SD ACCESS_FMT CHECK "access.log ausente o con formato no esperado: seccion 3 omitida"
elif [ "$GAWK" = 0 ]; then fnd SD NO_GAWK CHECK "sin gawk (mktime): seccion 3 omitida"
else
  echo "$LL" | grep -q '+0000\]' || say IND "el access.log no esta en +0000: revisar zona antes de correlacionar"
  echo "$ALF" | xargs zcat -f 2>/dev/null | "$AWK" -v since="$SINCE" -v thr="$THR" -v kv="$TMPD/kv" '
  BEGIN{FS="\"";split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec",M," ");for(i=1;i<=12;i++)mi[M[i]]=i}
  function ep(t){return mktime(substr(t,8,4)" "mi[substr(t,4,3)]" "substr(t,1,2)" "substr(t,13,2)" "substr(t,16,2)" "substr(t,19,2))}
  { i=index($1,"["); if(!i)next; t=substr($1,i+1,20); e=ep(t); if(e<=0)next
    lb=(mx>e)?mx-e:0; if(e>mx)mx=e; if(e<since)next
    if(!f1)f1=t; fl=t; split($3,b," "); st=b[1]; split($2,q," "); u=q[2]; p=u; sub(/\?.*/,"",p)
    ip=substr($1,1,index($1," ")-1); if($6~/^WordPress\//)WPU[ip]++; n++; S[st]++; hr=substr(t,1,14); H[hr]++; if(st~/^5/){H5[hr]++;e5++}
    if(lb>=10)H10[hr]++; R[substr(t,1,17)]++; I[ip]++
    if(lb>=thr){ns++;SL[p]++;if(lb>SX[p])SX[p]=lb}
    if($6~/rapyd-cloud-uptime/){m++;MS[st]++;MP[p" "st]++;if(lb>mmx)mmx=lb;if(lb>=thr){msl++;ML[msl]=t" >="lb"s "st}}
    if(p~/xmlrpc\.php$/)xr++; if(q[1]=="POST"&&p~/wp-login\.php$/)lg++; if(u~/add-to-cart=/)atc++
    if(p~/\/wp-json\/wc\/store/)wcs++; if(p~/wp-cron\.php$/)cr++; if(p~/admin-ajax\.php$/)aj++
    if(st=="404"&&p~/^\/wp-(content|includes)\/.*\.(js|css|png|jpe?g|gif|webp|svg|woff2?|ttf)$/){s4++;S4[p]++}
  }
  END{ printf "  INFO  %d requests entre %s y %s\n",n,f1,fl
    printf "  INFO  status:"; for(s in S)printf " %s=%d",s,S[s]; print ""
    print "  INFO  por hora (req / 5xx / requests con orden invertido >=10s):"; fflush()
    c="sort"; for(h in H)printf "          %s  %6d %5d %5d\n",h,H[h],H5[h],H10[h] | c; close(c)
    printf "  INFO  sondas del monitor: %d, status:",m; for(s in MS)printf " %s=%d",s,MS[s]
    printf ", >=%ss (cota inferior): %d, max >=%ds\n",thr,msl,mmx; k=(msl>6)?msl-5:1
    printf "  INFO  sondas por ruta:"; for(x in MP)printf " [%s]=%d",x,MP[x]; print ""
    for(j=k;j<=msl;j++)print "          "ML[j]
    for(r in R)if(R[r]>pk){pk=R[r];pkm=r}; printf "  INFO  pico %d req/min (%s)\n",pk,pkm
    print "  INFO  top IPs:"; fflush(); c="sort -k2 -rn | head -6"; for(x in I)printf "          %-40s %d\n",x,I[x] | c; close(c)
    for(x in I)if(I[x]>ti){ti=I[x];tip=x}
    print "  INFO  rutas con requests >="thr"s (cota inferior por orden de escritura), cuenta y max:"; fflush()
    c="sort -k2 -rn | head -10"; for(x in SL)printf "          %-60s %5d  max>=%ds\n",substr(x,1,60),SL[x],SX[x] | c; close(c)
    printf "  INFO  patrones: xmlrpc=%d wp-login-POST=%d add-to-cart=%d wc-store-api=%d wp-cron=%d admin-ajax=%d static-404=%d\n",xr,lg,atc,wcs,cr,aj,s4
    if(s4){fflush(); c="sort -k2 -rn | head -5"; for(x in S4)printf "          404 %-60s %d\n",substr(x,1,60),S4[x] | c; close(c)}
    printf "AL_TIWP=%d\nAL_N=%d\nAL_M=%d\nAL_MSL=%d\nAL_MMX=%d\nAL_NS=%d\nAL_PK=%d\nAL_TI=%d\nAL_TIP=\"%s\"\nAL_5=%d\nAL_S4=%d\nAL_XR=%d\nAL_LG=%d\nAL_ATC=%d\nAL_WCS=%d\n",WPU[tip],n,m,msl,mmx,ns,pk,ti,tip,e5,s4,xr,lg,atc,wcs > kv }'
  # shellcheck disable=SC1091
  [ -s "$TMPD/kv" ] && . "$TMPD/kv"
  say INFO "cota inferior: una linea se escribe al terminar; si antes se escribio una recibida mas tarde, duro al menos esa diferencia. Con poco trafico la cota da 0 aunque haya sido lento."
  if [ "${AL_M:-0}" = 0 ]; then say INFO "sin sondas del monitor (UA rapyd-cloud-uptime) en la ventana: otro dominio/host o logs rotados"
  elif [ "${AL_MSL:-0}" -gt 0 ]; then fnd IND MONITOR_SLOW_LB CHECK "$AL_MSL de $AL_M sondas del monitor tardaron >=${THR}s (cota inferior; max >=${AL_MMX}s)"
  else say OK "ninguna sonda del monitor muestra inversion >=${THR}s (no prueba que fueran rapidas si el trafico es bajo)"; fi
  [ "${AL_5:-0}" -gt 0 ] && fnd IND HTTP_5XX CHECK "$AL_5 respuestas 5xx en la ventana (ver por hora arriba; 500 LiteSpeed vs fatal PHP se distingue en secciones 4 y 5)"
  if [ "${AL_N:-0}" -gt 2000 ] && [ $((AL_TI*100/AL_N)) -ge 20 ]; then
    if [ $((AL_TIWP*100/(AL_TI>0?AL_TI:1))) -ge 80 ]; then say INFO "la IP top $AL_TIP ($AL_TI req) es loopback de WordPress (UA WordPress/): IP de salida del nodo, no visitantes"
    else fnd IND TRAFFIC_CONCENTRATED CUST "la IP $AL_TIP hizo $AL_TI de $AL_N requests ($((AL_TI*100/AL_N))%)"; fi; fi
  # duracion de "/" por pares de la misma IP del monitor (cuando sigue redirect) vs tiempo sin trafico previo
  echo "$ALF" | xargs zcat -f 2>/dev/null | "$AWK" -F'"' 'BEGIN{split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec",M," ");for(i=1;i<=12;i++)mi[M[i]]=i}
    {i=index($1,"[");if(!i)next;t=substr($1,i+1,20);e=mktime(substr(t,8,4)" "mi[substr(t,4,3)]" "substr(t,1,2)" "substr(t,13,2)" "substr(t,16,2)" "substr(t,19,2))
     split($1,a," ");split($2,r," ");p=r[2];sub(/\?.*/,"",p);split($3,s," ");print e,a[1],p,s[1],($6~/rapyd-cloud-uptime/)?"M":"-"}' \
  | sort -n -s -k1,1 | "$AWK" -v since="$SINCE" -v thr="$THR" -v idle="$IDLE" -v kv="$TMPD/kv2" '
    $5=="M"&&$3=="/"&&$4~/^30/{rt[$2]=$1;gp[$2]=$1-last;last=$1;next}
    $5=="M"&&($2 in rt)&&$1-rt[$2]<120{if(rt[$2]>=since){d=$1-rt[$2];b=(gp[$2]>=idle)?"I":"W";n[b]++;sm[b]+=d;if(d>=thr)sl[b]++;if(d>mx[b])mx[b]=d};delete rt[$2];last=$1;next}
    {last=$1}
    END{if(n["I"]+n["W"]==0){print "  INFO  sin pares de sonda / -> redirect en la ventana";exit}
      print "  INFO  duracion de / del monitor (hasta su siguiente pedido, misma IP) segun tiempo sin trafico previo:"
      printf "          sin trafico >=%ds: %4d sondas prom %.1fs max %ds >=%ss: %d\n",idle,n["I"],n["I"]?sm["I"]/n["I"]:0,mx["I"],thr,sl["I"]
      printf "          con trafico  <%ds: %4d sondas prom %.1fs max %ds >=%ss: %d\n",idle,n["W"],n["W"]?sm["W"]/n["W"]:0,mx["W"],thr,sl["W"]
      printf "PI_N=%d\nPI_A=%.1f\nPW_N=%d\nPW_A=%.1f\n",n["I"],n["I"]?sm["I"]/n["I"]:0,n["W"],n["W"]?sm["W"]/n["W"]:0 > kv}'
  # shellcheck disable=SC1091
  [ -s "$TMPD/kv2" ] && . "$TMPD/kv2"
  if [ "${PI_N:-0}" -ge 5 ] && [ "${PW_N:-0}" -ge 5 ] && ge "$PI_A" "$THR" && ge "$PI_A" "$(awk -v w="$PW_A" 'BEGIN{print w*2}')"; then
    fnd IND IDLE_COLD FIX "tras >=${IDLE}s sin trafico la / del monitor promedia ${PI_A}s ($PI_N sondas) contra ${PW_A}s con trafico previo ($PW_N): el pool arranca en frio"; fi
  { [ "${AL_XR:-0}" -gt 500 ] || [ "${AL_LG:-0}" -gt 200 ] || [ "${AL_ATC:-0}" -gt 300 ] || [ "${AL_WCS:-0}" -gt 300 ]; } && \
    fnd IND ABUSE_PATTERN CUST "volumen alto en endpoints de abuso (xmlrpc=$AL_XR login-POST=$AL_LG add-to-cart=$AL_ATC store-api=$AL_WCS)"
  [ "${AL_S4:-0}" -gt 50 ] && fnd IND STATIC_404 CUST "$AL_S4 404 sobre assets de wp-content/wp-includes: cada uno arranca WordPress completo"
fi

# ================= 4 LiteSpeed / LSAPI / cache de vhost
hdr "4 LiteSpeed y pool LSAPI"
INST=$(vkey instances "$VC"); MAXC=$(vkey maxConns "$VC"); CH=$(venv PHP_LSAPI_CHILDREN "$VC"); EX=$(venv LSAPI_EXTRA_CHILDREN "$VC")
say INFO "vhconf: instances=${INST:--} maxConns=${MAXC:--} PHP_LSAPI_CHILDREN=${CH:--} LSAPI_EXTRA_CHILDREN=${EX:--} memHardLimit=$(vkey memHardLimit "$VC")"
CFL=$(grep -iE '^\s*(enableCache|ls_enabled)\s' "$VC" 2>/dev/null | awk '{print $1"="$2}' | sort -u | tr '\n' ' ')
say INFO "pool idle: runOnStartUp=$(vkey runOnStartUp "$VC") autoStart=$(vkey autoStart "$VC") maxIdleTime=$(vkey maxIdleTime "$VC") LSAPI_PGRP_MAX_IDLE=$(venv LSAPI_PGRP_MAX_IDLE "$VC") PHP_LSAPI_MAX_IDLE=$(venv PHP_LSAPI_MAX_IDLE "$VC") (vacio = default)"
say INFO "cache vhost: ${CFL:-sin claves enableCache/ls_enabled}"
say INFO "rapyd config php.max-workers: $(rapyd config get --key php.max-workers --slug "$SLUG" 2>&1 | tr '\n' ' ' | cut -c1-100)"
say INFO "rapyd config cache.enable:    $(rapyd config get --key cache.enable --slug "$SLUG" 2>&1 | tr '\n' ' ' | cut -c1-100)"
if echo "$CFL" | grep -q 'ls_enabled=0'; then
  if [ "${HH:-0}" -gt 0 ]; then fnd IND CACHE_OFF FIX-OK "vhconf dice cache apagado (${CFL% }) pero la home dio HIT $HH veces: verificar que config esta cargada"
  else fnd CONF CACHE_OFF FIX-OK "cache de LiteSpeed apagado en el vhconf (${CFL% }) y sin HIT en la seccion 2"; fi; fi
# enforcement real: rtreport (root) EXTAPP del vhost
RTL=$(cat "$RT"* 2>/dev/null | grep -F "$SLUG" | grep -E 'EXTAPP|REQ_RATE')
if [ -n "$RTL" ]; then echo "$RTL" | cut -c1-230 | sed 's/^/        /'
  CMX=$(echo "$RTL" | grep EXTAPP | grep -oE 'CMAXCONN: [0-9]+' | head -1 | awk '{print $2}')
  INU=$(echo "$RTL" | grep EXTAPP | grep -oE 'INUSE_CONN: [0-9]+' | awk '{s+=$2}END{print s+0}')
  WQ=$(echo "$RTL" | grep EXTAPP | grep -oE 'WAITQUE_DEPTH: [0-9]+' | awk '{s+=$2}END{print s+0}')
  [ "$WQ" -gt 0 ] && fnd CONF POOL_QUEUE CHECK "ahora hay $WQ requests en cola esperando PHP (WAITQUE_DEPTH), en uso $INU de ${CMX:-?}"
else CMX=; say SD "rtreport sin lineas para $SLUG ($RT)"; fi
if [ -n "$INST" ] && [ "$INST" -gt 1 ]; then
  if [ -n "$CMX" ] && [ "$CMX" -le "$INST" ]; then fnd CONF INSTANCES FIX "instances=$INST con maxConns=$MAXC: LiteSpeed aplica CMAXCONN=$CMX (config + rtreport)"
  else fnd IND INSTANCES FIX "instances=$INST con maxConns=$MAXC en vhconf; falta confirmar CMAXCONN en rtreport"; fi
fi
[ "${EX:-0}" = 1 ] && fnd BUG EXTRA_CHILDREN PLAT "LSAPI_EXTRA_CHILDREN=1: rampa lenta del pool bajo picos (documentado a Ayush)"
# vhconf escrito pero no cargado
VT=$VC.txt
if [ ! -f "$VT" ]; then fnd IND VHCONF_NOT_PARSED FIX "no existe vhconf.conf.txt: el vhost no fue parseado desde el ultimo cambio"
elif [ "$VC" -nt "$VT" ]; then DK=
  for k in instances maxConns runOnStartUp autoStart; do a=$(vkey "$k" "$VC"); b=$(vkey "$k" "$VT"); [ -n "$b" ] && [ "$a" != "$b" ] && DK="$DK $k:$b->$a"; done
  a=$(venv PHP_LSAPI_CHILDREN "$VC"); b=$(venv PHP_LSAPI_CHILDREN "$VT"); [ -n "$b" ] && [ "$a" != "$b" ] && DK="$DK CHILDREN:$b->$a"
  MT=$(stat -c %y "$VC" | cut -c1-19); PT=$(stat -c %y "$VT" | cut -c1-19)
  if [ -n "$DK" ]; then fnd CONF VHCONF_NOT_LOADED FIX "vhconf escrito $MT, ultimo parseo $PT; difiere en:$DK"
  else fnd IND VHCONF_NOT_LOADED CHECK "vhconf escrito $MT, ultimo parseo $PT; claves de pool iguales, el cambio es otro"; fi
  for bk in "$VC.rsm.bk" "$VC.bak"; do [ -f "$bk" ] && { say INFO "diff $(basename "$bk") -> vhconf.conf:"; diff "$bk" "$VC" | head -12 | cut -c1-150 | sed 's/^/        /'; break; }; done
else for k in instances maxConns; do a=$(vkey "$k" "$VC"); b=$(vkey "$k" "$VT")
  [ "$a" != "$b" ] && fnd IND VHCONF_DIFF FIX "$k en disco=$a y parseado=$b"; done; fi
# error.log del servidor en la ventana
EL=$SLOG/error.log
if [ -r "$EL" ] && tail -n 1 "$EL" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:'; then
  awk -v s="$SINCES" '($1" "substr($2,1,8))>=s' "$EL" > "$TMPD/el"
  say INFO "error.log: $(wc -l < "$TMPD/el") lineas en ventana desde $(head -1 "$TMPD/el" | cut -c1-19)"
  for p in 'max children' 'No request delivery notification' "Possible mis-configuration: 'Instances'" 'ExtConn timeout|Connection reset|Broken pipe' 'Out of memory|Cannot allocate'; do
    a=$(grep -ciE "$p" "$TMPD/el"); b=$(grep -iE "$p" "$TMPD/el" | grep -cF "$SLUG")
    [ "$a" -gt 0 ] && say INFO "  '$p': total=$a con $SLUG=$b; ultima: $(grep -iE "$p" "$TMPD/el" | grep -F "$SLUG" | tail -1 | cut -c1-150)"
  done
  MXC=$(grep -iE 'max children' "$TMPD/el" | grep -cF "$SLUG"); DL=$(grep -i 'No request delivery notification' "$TMPD/el" | grep -cF "$SLUG")
  [ "$MXC" -gt 0 ] && { fnd CONF POOL_SATURATED CHECK "LiteSpeed registro limite de children $MXC veces para $SLUG en la ventana"
    grep -iE 'max children' "$TMPD/el" | grep -F "$SLUG" | cut -c1-13 | sort | uniq -c | tail -8 | sed 's/^/        /'; }
  [ "$DL" -gt 0 ] && fnd CONF LSAPI_DEADLOCK CHECK "$DL 'No request delivery notification' para $SLUG en la ventana"
else fnd SD ERRORLOG CHECK "$EL ilegible o con formato no esperado"; fi
# pool en vivo
ps -u "$U" -o pid=,etimes=,pcpu=,rss=,wchan:18=,args= 2>/dev/null | grep '[l]sphp' > "$TMPD/ps"
NP=$(wc -l < "$TMPD/ps"); NB=$(grep -c 'lsphp:/' "$TMPD/ps")
say INFO "lsphp de $U ahora: $NP procesos, $NB con script en curso (titulo lsphp:/...)"
sort -k3 -rn "$TMPD/ps" | head -8 | cut -c1-170 | sed 's/^/        /'
LIM=${CMX:-${CH:-0}}; [ "$LIM" -gt 0 ] && [ "$NB" -ge "$LIM" ] && fnd CONF POOL_FULL_NOW CHECK "$NB scripts en curso con limite efectivo $LIM: pool lleno en este momento"
# workers esperando I/O externo
PIDS=$(awk '{print $1}' "$TMPD/ps" | paste -sd'|')
if [ -n "$PIDS" ]; then
  ss -tnpH state established 2>/dev/null | grep -E "pid=($PIDS)," | awk '{print $4, $NF}' | grep -vE '^(127\.0\.0\.1|\[::1\]|\[::ffff:127)' | grep -vE ':(3306|6379) ' > "$TMPD/ext"
  [ -s "$TMPD/ext" ] && { fnd IND EXT_HTTP_WAIT CUST "$(wc -l < "$TMPD/ext") conexiones salientes abiertas desde lsphp (API externa en curso)"; head -6 "$TMPD/ext" | cut -c1-150 | sed 's/^/        /'; }
fi

# ================= 5 PHP
hdr "5 PHP"
for f in "$PHPD"/*.ini; do [ -f "$f" ] || continue
  grep -HnE '^\s*(open_basedir|opcache\.(enable|memory_consumption|interned_strings_buffer|max_accelerated_files|revalidate_freq|validate_timestamps)|memory_limit|max_execution_time|realpath_cache_size)\s*=' "$f" \
   | sed "s#$PHPD/##" | cut -c1-160 | sed 's/^/        /'; done
OBL=$(grep -HE '^\s*open_basedir\s*=' "$PHPD"/*.ini 2>/dev/null | tail -1); OBV=$(echo "$OBL" | sed -E 's/^[^=]*=//; s/["[:space:]]//g')
if [ -n "$OBV" ]; then OB=1; fnd BUG OPEN_BASEDIR PLAT "open_basedir efectivo en $(basename "${OBL%%:*}"): PHP apaga el realpath cache en web (escalado a Ayush)"
else OB=0; [ -n "$OBL" ] && say OK "open_basedir anulado en $(basename "${OBL%%:*}") (ultimo en la cadena); runtime: --php-probe"; fi
PE=$(find "$LOGD" -maxdepth 1 -name 'php_errors.log*' -mmin -$((HOURS*60+60)) 2>/dev/null | sort)
if [ -n "$PE" ] && [ "$GAWK" = 1 ]; then
  echo "$PE" | xargs zcat -f 2>/dev/null | "$AWK" -v since="$SINCE" '
    BEGIN{split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec",M," ");for(i=1;i<=12;i++)mi[M[i]]=i}
    /^\[[0-9][0-9]-[A-Z][a-z][a-z]-[0-9]{4} /{e=mktime(substr($0,9,4)" "mi[substr($0,5,3)]" "substr($0,2,2)" "substr($0,14,2)" "substr($0,17,2)" "substr($0,20,2)); if(e>=since)print}' > "$TMPD/pe"
  FT=$(grep -c 'PHP Fatal error' "$TMPD/pe"); MET=$(grep -c 'Maximum execution time' "$TMPD/pe"); WN=$(grep -c 'PHP Warning' "$TMPD/pe")
  say INFO "php_errors en ventana: fatal=$FT max_execution_time=$MET warning=$WN deprecated=$(grep -c 'PHP Deprecated' "$TMPD/pe")"
  grep -E 'PHP (Fatal|Warning)' "$TMPD/pe" | sed -E 's/^\[[^]]*\] //; s/[0-9]+/N/g' | cut -c1-150 | sort | uniq -c | sort -rn | head -5 | sed 's/^/        /'
  [ "$FT" -gt 0 ] && fnd CONF PHP_FATALS CUST "$FT fatales PHP en la ventana (500 de aplicacion, distinto de saturacion LiteSpeed)"
  [ "$MET" -gt 0 ] && fnd CONF PHP_TIMEOUTS CHECK "$MET requests cortados por max_execution_time"
  [ "$WN" -gt 50000 ] && fnd IND WARNING_FLOOD CUST "$WN warnings PHP en ${HOURS}h: escritura de log en cada request"
elif [ -f "$LOGD/php_errors.log" ] && [ ! -s "$LOGD/php_errors.log" ]; then say INFO "php_errors.log vacio (mtime $(stat -c %y "$LOGD/php_errors.log" | cut -c1-10)): PHP no registra errores ahi"
else say SD "sin php_errors.log en la ventana o sin gawk"; fi
if [ "$PROBE" = 1 ] && [ -d "$WR" ]; then
  PF=$WR/sd-probe-$RANDOM$RANDOM.php
  cat > "$PF" <<'PHP'
<?php header('Cache-Control: no-store');
$o=function_exists('opcache_get_status')?@opcache_get_status(false):false;
echo 'php=',PHP_VERSION,' open_basedir=',ini_get('open_basedir')?'set':'empty',' realpath_used=',realpath_cache_size(),' memory_limit=',ini_get('memory_limit'),"\n";
if($o){$m=$o['memory_usage'];$s=$o['opcache_statistics'];
echo 'op_free_mb=',round($m['free_memory']/1048576,1),' op_used_mb=',round($m['used_memory']/1048576,1),' wasted_pct=',round($m['current_wasted_percentage'],1),"\n";
echo 'hit_rate=',round($s['opcache_hit_rate'],2),' scripts=',$s['num_cached_scripts'],' max_keys=',$s['max_cached_keys'],' oom_restarts=',$s['oom_restarts'],' hash_restarts=',$s['hash_restarts'],' manual_restarts=',$s['manual_restarts'],' since=',gmdate('Y-m-d H:i',$s['start_time']),"\n";
echo 'revalidate_freq=',ini_get('opcache.revalidate_freq'),' validate_timestamps=',ini_get('opcache.validate_timestamps'),"\n";}
else echo "opcache=unavailable\n";
PHP
  chown "$U" "$PF" 2>/dev/null; chmod 644 "$PF"
  curl -sk --max-time 30 -A "$BUA" --resolve "$DOM:443:$LB" "https://$DOM/$(basename "$PF")" > "$TMPD/pp" 2>/dev/null
  rm -f "$PF"; PF=
  if grep -q '^php=' "$TMPD/pp"; then sed 's/^/        /' "$TMPD/pp"
    pv(){ grep -oE "$1=[0-9.]+" "$TMPD/pp" | head -1 | cut -d= -f2; }
    [ "$OB" = 1 ] && [ "$(pv realpath_used)" = 0 ] && fnd CONF REALPATH_OFF PLAT "realpath cache usado=0 en runtime web con open_basedir (2do angulo del BUG)"
    { [ "$(pv oom_restarts)" != 0 ] || ! ge "$(pv op_free_mb)" 5; } && [ -n "$(pv op_free_mb)" ] && fnd CONF OPCACHE_FULL FIX "opcache libre $(pv op_free_mb)MB, oom_restarts=$(pv oom_restarts)"
    S=$(pv scripts); K=$(pv max_keys); [ -n "$K" ] && [ "$K" -gt 0 ] && [ $((S*100/K)) -ge 90 ] && fnd CONF OPCACHE_KEYS FIX "opcache con $S de $K claves"
    [ "$(num "$(pv manual_restarts)")" -gt 10 ] && fnd IND OPCACHE_RESETS PLAT "$(pv manual_restarts) opcache_reset manuales desde $(grep -oE 'since=[0-9: -]+' "$TMPD/pp" | cut -d= -f2)"
  else fnd SD PHP_PROBE CHECK "la sonda PHP no devolvio datos: $(head -c 120 "$TMPD/pp" | tr '\n' ' ')"; fi
else say INFO "runtime opcache/realpath no medido (usar --php-probe)"; fi

# ================= 6 base de datos y WordPress
hdr "6 MariaDB y WordPress"
MDB=mariadb; systemctl cat mariadb >/dev/null 2>&1 || MDB=mysql
say INFO "$MDB: $(systemctl is-active $MDB 2>/dev/null) desde $(systemctl show $MDB -p ActiveEnterTimestamp --value 2>/dev/null) NRestarts=$(systemctl show $MDB -p NRestarts --value 2>/dev/null)"
NRS=$(systemctl show $MDB -p NRestarts --value 2>/dev/null)
[ "$(num "$NRS")" -gt 0 ] && fnd IND DB_RESTARTS CHECK "MariaDB con NRestarts=$NRS desde $(systemctl show $MDB -p ActiveEnterTimestamp --value 2>/dev/null): correr mariadb-diag.sh"
AE=$(date -d "$(systemctl show $MDB -p ActiveEnterTimestamp --value 2>/dev/null)" +%s 2>/dev/null)
[ -n "$AE" ] && [ "$AE" -ge "$SINCE" ] && fnd IND DB_RESTARTED CHECK "MariaDB arranco dentro de la ventana: correr mariadb-diag.sh"
WC=$WR/wp-config.php
DBN=$(grep -oP "define\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]\K[^'\"]+" "$WC" 2>/dev/null | head -1)
PFX=$(grep -oP "^\s*\\\$table_prefix\s*=\s*['\"]\K[^'\"]+" "$WC" 2>/dev/null | head -1)
say INFO "wp-config: DB_NAME=${DBN:--} prefix=${PFX:--} $(grep -oE "define\(\s*'(WP_CACHE|DISABLE_WP_CRON|WP_REDIS_HOST|WP_REDIS_PATH|WP_REDIS_SCHEME)'\s*,\s*[^)]+" "$WC" 2>/dev/null | sed -E "s/define\(\s*'//; s/'\s*,\s*/=/" | tr -d "'\" " | tr '\n' ' ')"
gk(){ awk -F'"' -v k="$1" '$1~"^[[:space:]]*"k"[[:space:]]*="{print $2;exit}' "$RSM" 2>/dev/null; }
DU=$(gk db_user); DP=$(gk db_password); DH=$(gk db_host)
if [ "$NODB" = 1 ] || [ -z "$DU" ]; then say SD "sin consultas a MariaDB (--no-db o sin credenciales en $RSM)"
else
  (umask 077; printf '[client]\nuser=%s\npassword=%s\nhost=%s\nconnect-timeout=5\n' "$DU" "$DP" "${DH:-127.0.0.1}" > "$TMPD/my.cnf")
  MY(){ timeout 25 mysql --defaults-extra-file="$TMPD/my.cnf" -N -B -e "$1" 2>/dev/null; }
  MYT(){ timeout 25 mysql --defaults-extra-file="$TMPD/my.cnf" -t -e "$1" 2>/dev/null; }
  G=$(MY "SELECT @@version,@@innodb_buffer_pool_size DIV 1048576,@@max_connections,@@slow_query_log,@@long_query_time")
  if [ -z "$G" ]; then fnd SD DB_CONNECT CHECK "no se pudo consultar MariaDB con las credenciales de RSM"
  else read -r VER BPM MAXCN SQL LQT <<<"$G"
    MY "SHOW GLOBAL STATUS WHERE Variable_name IN ('Uptime','Threads_running','Threads_connected','Max_used_connections','Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads','Slow_queries','Created_tmp_disk_tables','Questions')" > "$TMPD/gs"
    gs(){ awk -v k="$1" '$1==k{print $2}' "$TMPD/gs"; }
    RR=$(gs Innodb_buffer_pool_read_requests); RD=$(gs Innodb_buffer_pool_reads)
    HIT=$(awk -v a="${RR:-0}" -v b="${RD:-0}" 'BEGIN{if(a>0)printf "%.2f",100*(1-b/a); else print "-"}')
    DATA=$(MY "SELECT ROUND(SUM(data_length+index_length)/1048576) FROM information_schema.tables WHERE engine='InnoDB'")
    QPS=$(awk -v q="$(gs Questions)" -v u="$(gs Uptime)" 'BEGIN{if(u>0)printf "%.0f",q/u}')
    say INFO "$VER bp=${BPM}MB datos_innodb=${DATA:-?}MB hit=${HIT}% running=$(gs Threads_running) conn=$(gs Threads_connected)/$MAXCN max_used=$(gs Max_used_connections) qps_prom=$QPS"
    say INFO "slow_query_log=$SQL long_query_time=$LQT slow_queries=$(gs Slow_queries) tmp_disk=$(gs Created_tmp_disk_tables) env=$(systemctl show $MDB -p Environment --value 2>/dev/null | tr ' ' '\n' | grep -i autoconf)"
    [ -n "$DATA" ] && [ "${BPM:-0}" -gt 0 ] && [ $((BPM*4)) -lt "$DATA" ] && [ "$HIT" != - ] && ! ge "$HIT" 99 && \
      fnd IND BUFFER_POOL_SMALL PLAT "buffer pool ${BPM}MB para ${DATA}MB InnoDB con hit ${HIT}% (jelAutoConf/JELASTIC_AUTOCONFIG)"
    [ "$SQL" = 0 ] && fnd INFO SLOWLOG_OFF FIX "slow_query_log apagado: no hay historia de queries lentas"
    [ "$(num "$(gs Threads_running)")" -ge 20 ] && fnd CONF DB_BUSY CHECK "Threads_running=$(gs Threads_running) ahora"
    MYT "SELECT id,db,time,LEFT(state,20) state,LEFT(REPLACE(info,'\n',' '),110) q FROM information_schema.processlist WHERE command<>'Sleep' AND info IS NOT NULL AND id<>CONNECTION_ID() ORDER BY time DESC LIMIT 8" | sed 's/^/        /'
    LQ=$(MY "SELECT COUNT(*) FROM information_schema.processlist WHERE command<>'Sleep' AND time>=5 AND info IS NOT NULL")
    [ "$(num "$LQ")" -gt 0 ] && fnd CONF DB_LONG_QUERY CHECK "$LQ queries corriendo hace >=5s en este momento (ver processlist)"
    LT=$(MY "SELECT COUNT(*) FROM information_schema.INNODB_TRX WHERE trx_started < NOW() - INTERVAL 60 SECOND")
    [ "$(num "$LT")" -gt 0 ] && fnd CONF DB_LONG_TRX CHECK "$LT transacciones InnoDB abiertas hace >60s"
    if [ -n "$DBN" ] && [ -n "$PFX" ]; then
      T="\`$DBN\`.\`${PFX}options\`"
      AL=$(MY "SELECT COUNT(*),ROUND(SUM(LENGTH(option_value))/1024) FROM $T WHERE autoload IN ('yes','on','auto-on','auto')")
      say INFO "autoload: $(echo "$AL" | awk '{print $1" opciones, "$2" KB"}')"
      MYT "SELECT option_name,ROUND(LENGTH(option_value)/1024) kb FROM $T WHERE autoload IN ('yes','on','auto-on','auto') ORDER BY LENGTH(option_value) DESC LIMIT 5" | sed 's/^/        /'
      [ "$(num "$(echo "$AL" | awk '{print $2}')")" -ge 1024 ] && fnd IND AUTOLOAD_BIG CUST "autoload de $(echo "$AL" | awk '{print $2}') KB cargado en cada request"
      MY "SELECT option_name,LEFT(option_value,120) FROM $T WHERE option_name IN ('litespeed.conf.cache','litespeed.conf.cache-mobile','litespeed.conf.cache-drop_qs','litespeed.conf.object','litespeed.conf.cache-priv','litespeed.conf.cache-ttl_pub')" | tr '\t\n' '= ' | sed 's/^/        LSCWP: /;s/$/\n/'
      LSC=$(MY "SELECT option_value FROM $T WHERE option_name='litespeed.conf.cache'")
      [ "$LSC" = 0 ] || [ "$LSC" = "" ] && [ -n "$(MY "SELECT 1 FROM $T WHERE option_name='litespeed.conf.cache'")" ] && fnd CONF LSCWP_CACHE_OFF FIX-OK "LSCWP con cache apagado (litespeed.conf.cache=$LSC)"
      AP=$(MY "SELECT option_value FROM $T WHERE option_name='active_plugins'")
      say INFO "plugins activos: $(echo "$AP" | grep -oE 'i:[0-9]+;s:' | wc -l)"
      echo "$AP" | grep -q 'query-monitor/' && fnd CONF QUERY_MONITOR CUST "Query Monitor activo en este site"
      AS=$(MY "SELECT COUNT(*) FROM \`$DBN\`.\`${PFX}actionscheduler_actions\` WHERE status='pending' AND scheduled_date_gmt < UTC_TIMESTAMP() - INTERVAL 1 HOUR")
      [ "$(num "$AS")" -gt 1000 ] && fnd IND ACTIONSCHEDULER_BACKLOG CUST "$AS acciones de Action Scheduler vencidas hace >1h"
      MYT "SELECT table_name t,ROUND((data_length+index_length)/1048576) mb,table_rows filas FROM information_schema.tables WHERE table_schema='$DBN' ORDER BY data_length+index_length DESC LIMIT 5" | sed 's/^/        /'
    fi
  fi
fi
HT=$WR/.htaccess
if grep -q 'marker MOBILE start' "$HT" 2>/dev/null && type MY >/dev/null 2>&1; then
  [ "$(MY "SELECT option_value FROM \`$DBN\`.\`${PFX}options\` WHERE option_name='litespeed.conf.cache-mobile'" 2>/dev/null)" = 0 ] && \
    fnd CONF MOBILE_MARKER_ORPHAN FIX "marker MOBILE (vary ismobile) en .htaccess con cache-mobile=0: variante mobile fria"
fi

# ================= 7 object cache
hdr "7 object cache"
OC=$WR/wp-content/object-cache.php
KA=$(systemctl is-active keydb 2>/dev/null)
T0=$(date +%s%N); KP=$(timeout 3 keydb-cli -s /var/run/redis/redis.sock ping 2>/dev/null); T1=$(date +%s%N)
say INFO "keydb: servicio=${KA:--} ping=${KP:-sin respuesta} ($(( (T1-T0)/1000000 ))ms incluyendo el cliente)"
timeout 3 keydb-cli -s /var/run/redis/redis.sock info 2>/dev/null | tr -d '\r' | grep -E '^(used_memory_human|maxmemory_human|maxmemory_policy|evicted_keys|rejected_connections|connected_clients|instantaneous_ops_per_sec):' | tr '\n' ' ' | sed 's/^/        /;s/$/\n/'
if [ -f "$OC" ]; then
  say INFO "drop-in: $(stat -c '%s bytes %U %y' "$OC" | cut -c1-60) | $(grep -m1 -iE 'Plugin Name|@package|Description' "$OC" | cut -c1-80)"
  [ "$KP" != PONG ] && fnd CONF OBJCACHE_NO_BACKEND FIX "object-cache.php presente y KeyDB no responde: cada request intenta conectar"
  grep -qE 'eval\s*\(|gzinflate\s*\(|str_rot13\s*\(' "$OC" && fnd IND OBJCACHE_SUSPICIOUS CHECK "object-cache.php contiene eval/gzinflate/str_rot13: revisar (patron de city-skills)"
else say INFO "sin object-cache.php"; fi

# ================= 8 nodo
hdr "8 nodo"
L1=$(cut -d' ' -f1 /proc/loadavg); NC=$(nproc)
ge "$L1" $((NC*2)) && fnd IND NODE_LOAD CHECK "load1=$L1 con $NC CPUs"
ps -eo pid,user,etimes,pcpu,rss,comm --sort=-pcpu | head -8 | sed 's/^/        /'
free -m | awk 'NR==2{printf "        mem total=%sMB usada=%sMB disponible=%sMB\n",$2,$3,$7}'
[ -r /sys/fs/cgroup/memory.events ] && say INFO "memory.events: $(tr '\n' ' ' < /sys/fs/cgroup/memory.events)"
awk 'NR>2 && $NF>0 {print "        UBC failcnt: "$0}' /proc/user_beancounters 2>/dev/null | head -5
CS=; for f in /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/cpu,cpuacct/cpu.stat /sys/fs/cgroup/cpu/cpu.stat; do [ -r "$f" ] && { CS=$f; break; }; done
FC=/sys/fs/cgroup/memory/memory.failcnt; [ -r "$FC" ] || FC=
if [ -n "$CS$FC" ]; then
  f1=$(cat "$FC" 2>/dev/null); t1=$(awk '$1=="nr_throttled"{print $2}' "$CS" 2>/dev/null); sleep 15
  f2=$(cat "$FC" 2>/dev/null); t2=$(awk '$1=="nr_throttled"{print $2}' "$CS" 2>/dev/null)
  say INFO "acumulados: failcnt=${f2:--} nr_throttled=${t2:--}; en 15s: failcnt +$(( ${f2:-0}-${f1:-0} )) nr_throttled +$(( ${t2:-0}-${t1:-0} ))"
  [ $(( ${f2:-0}-${f1:-0} )) -gt 0 ] && fnd CONF MEM_LIMIT_NOW CHECK "el contenedor esta chocando el limite de memoria ahora (failcnt +$(( f2-f1 )) en 15s)"
  [ $(( ${t2:-0}-${t1:-0} )) -gt 100 ] && fnd CONF CPU_THROTTLED_NOW CHECK "throttling de CPU ahora (+$(( t2-t1 )) periodos en 15s)"
fi
OOM=$(dmesg -T 2>/dev/null | grep -iE 'killed process' | tail -5)
[ -n "$OOM" ] && { say INFO "ultimos OOM kills (dmesg, correlacionar hora):"; echo "$OOM" | cut -c1-150 | sed 's/^/        /'; }
df -hP / /var/lib/mysql /home 2>/dev/null | awk 'NR>1' | sort -u | while read -r _ sz us _ pc mp; do
  echo "        disco $mp $us/$sz ($pc)"; [ "${pc%\%}" -ge 95 ] && echo "DISKFULL $mp $pc" >> "$TMPD/df"; done
[ -s "$TMPD/df" ] && fnd CONF DISK_FULL FIX "disco casi lleno: $(tr '\n' ' ' < "$TMPD/df")"
WG=$(ps -eo etimes=,args= | grep '[w]get' ); NW=$(echo "$WG" | grep -c .)
[ "$NW" -gt 0 ] && say INFO "wget en curso: $NW, mas viejo $(echo "$WG" | sort -rn | head -1 | awk '{print $1}')s"
[ "$NW" -gt 5 ] && fnd BUG WGET_PILEUP PLAT "$NW wget apilados (RapydCron sin timeout ni flock)"
ps -eo pid,etimes,pcpu,args | grep -iE '[b]ackup-tool|[c]omet|[m]onarx|[g]oofys' | cut -c1-140 | sed 's/^/        /'

# ================= 9 resumen
hdr "9 resumen ($(date -u '+%F %T') UTC)"
FF=$OUTDIR/slow-diag-$SLUG.findings
: > "$FF"
if [ ${#FIND[@]} -eq 0 ]; then say OK "sin hallazgos"
else for o in BUG CONF IND SD INFO; do for f in "${FIND[@]}"; do IFS='|' read -r l c k t <<<"$f"; [ "$l" = "$o" ] || continue
  printf '  %-5s %-7s %-22s %s\n' "$l" "$k" "$c" "$t"; echo "$f" >> "$FF"; done; done; fi
cat <<'EOF'
  clases: FIX candidato para slow-fix.sh | FIX-OK fix que necesita OK del cliente | PLAT escalar a Ayush
          CUST lado cliente (plugin/contenido/trafico) | CHECK falta evidencia para atribuir
  La seccion 2 vale solo para las muestras tomadas ahora. La ventana del aviso la cubre la seccion 3
  (cotas inferiores). Ningun hallazgo nombra un emisor: los IND necesitan 2do angulo antes de un mensaje al cliente.
EOF
echo "  informe: $OUT | hallazgos: $FF"
