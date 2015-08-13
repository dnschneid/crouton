echo '<table class="outer">'
echo '<tr class="outer">'
echo '<th class="outer"></th>'
echo '<th class="outer">Status</th>'
for test in $tests; do
    cnt=0
    for mach in $machines; do
        ncnt="`echo "$mach/results/$test."*"-test" | wc -w`"
        if [ "$ncnt" -gt "$cnt" ]; then
            cnt="$ncnt"
        fi
    done
    testshort="$test"
    if [ "$cnt" -lt 3 ]; then
        testshort="${test%%-*}"
    fi
    echo "<th class=\"outer\" title=\"$test\">$testshort</th>"
done
echo '</tr>'

for mach in $machines; do
    echo '<tr class="outer">'
    echo "<th class=\"outer\"><a href="$mach/results/"><pre>$mach</pre></a></th>"
    status="`awk 'BEGIN {RS="|";FS="="} $1~/^Status/{print $2}' "$mach/status"`"
    status2="`awk 'BEGIN {RS="|";FS="="} $1~/^Status2/{print $2}' "$mach/status"`"
    statusid="UNKNOWN"
    if [ -n "$status2" ]; then
        if [ "$status2" = "GOOD" ]; then
            statusid="PASSED"
        else
            statusid="FAILED"
        fi
    else
        if [ "$status" = "Running" -o "$status" = "Completed" ]; then
            statusid="UNKNOWN"
        elif [ "$status" = "Queued" ]; then
            statusid="BLANK"
        else
            statusid="FAILED"
        fi
    fi
    echo "<th class=\"outer\" id=\"$statusid\">$status</td>"
    for test in $tests; do
        echo '<td class="outer">'
        echo '<table class="inner">'
        echo '<tr class="inner">'
        for fulltest in "$mach/results/$test."*"-test"; do
            if [ ! -f "$fulltest" ]; then
                echo "<td class=\"inner\" id=\"BLANK\">&nbsp;</td>"
                break
            fi
            fulllog="${fulltest%-test}"
            short="${fulllog#$mach/results/$test.}"
            short="${short%.0}"
            xshort="`echo $short | sed -e 's/^\([a-z][a-z]\)[a-z]*/\1/'`"
            status="`tail -n 1 "$fulltest" | sed -n 's/.*TEST \([A-Z]*\):.*/\1/p'`"
            echo "<td class=\"inner\" id=\"${status:-UNKNOWN}\"><a title=\"$short\" href=\"$fulllog\">$xshort</a></td>"
        done
        echo '</tr>'
        echo '</table>'
        echo '</td>'
    done
    echo '</tr>'
done

echo '</table>'
