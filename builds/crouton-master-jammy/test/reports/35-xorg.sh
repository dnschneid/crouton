## Add output from 35-xorg tests
test="35-xorg"

xorgreleases="`for mach in $machines; do
    for fulltest in "$mach/results/$test."*"-test"; do
        if [ ! -f "$fulltest" ]; then
            continue
        fi
        fulllog="${fulltest%.*-test}"
        short="${fulllog#$mach/results/$test.}"
        echo $short
    done
done | sort -u`"

if [ -z "$xorgreleases" ]; then
    exit 0
fi

echo "<h2>$test results</h2>"
echo '<table class="outer">'
echo '<tr class="outer">'
echo '<th class="outer"></th>'
for release in $xorgreleases; do
    cnt=0
    echo "<th class="outer">$release</th>"
done
echo '</tr>'

for mach in $machines; do
    onetest="`ls "$mach/results/$test."*"-test" 2>/dev/null | tail -n 1`"
    if [ ! -f "$onetest" ]; then
        continue
    fi

    echo '<tr class="outer">'
    echo "<th class="outer"><pre>$mach</pre></th>"
    for release in $xorgreleases; do
        # Check out the latest test only
        besttest="`ls "$mach/results/$test.$release."*"-test" 2>/dev/null | sort | tail -n 1`"
        if [ ! -f "$besttest" ]; then
            echo '<td class="outer">&nbsp;</td>'
            continue
        fi

#if [ -z "$driinfo" ] || [ -z "$render" ]; then
#            color="pink"
#         elif ! echo "$driinfo" | grep -q 'i9.5' || ! echo "$render" | grep -q 'Intel'; then
#            color="yellow"
#         fi

        awk '
/ ====\/GLX info/ { g=3 }
(g == 2) && /OpenGL renderer string: / {
    renderer=$0
    gsub(/.*OpenGL renderer string: /, "", renderer)
}
(g == 1) && /==glxinfo/ { g=2 }
(g == 1) {
    key=$0; sub(/:.*$/, "", key); gsub(/^.* /, "", key)
    val=$0; sub(/^[^:]*:/, "", val)
    data[key] = val
}
/ ====GLX info/ { g=1 }
END {
    split(data["uname"], kernel, " ")
    sub(/^.*: /, "", data["xdriinfo"])
    statusid="PASSED"
    if (g != 3) {
        statusid="UNKNOWN"
    } else if (data["xdriinfo"] !~ /i9.5/ || renderer !~ /Intel/) {
        statusid="FAILED"
    }
    print "<td class=\"outer\" id=\"" statusid "\"><pre>"
    print "id: " data["vendor"] "/" data["device"]
    print "kernel: " kernel[3]
    print "driinfo: " data["xdriinfo"]
    print "renderer: " renderer
    print "</pre></td>"
}
' "$besttest"
    done
    echo '</tr>'
done

echo '</table>'

