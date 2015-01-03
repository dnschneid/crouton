
tests="`ls */results/w*-test | sed -e 's|.*/||;s|\..*||' | sort | uniq`"

if [ -z "$tests" ]; then
    exit 0
fi

for test in $tests; do
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

echo "<h2>$test</h2>"
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

        fulltest="${besttest%-test}"
        image="${besttest%-test}-snapshot.jpg"

        status="`tail -n 1 "$besttest" | sed -n 's/.*TEST \([A-Z]*\):.*/\1/p'`"
        tdid="${status:-UNKNOWN}"
        if [ -f "$image" ]; then
            thumbdir="$mach/results.thumb"
            thumb="${image#$mach/results/}"
            thumb="$thumbdir/$thumb"

            if [ ! -f "$thumb" -o "$image" -nt "$thumb" ]; then
                mkdir -p "$thumbdir"
                convert -resize 100x100 -quality 90 "$image" "$thumb"
            fi
        else
            if grep -q "unsupported combination" "$besttest"; then
                tdid="BLANK"
            fi
        fi

        echo "<td class=\"outer\" id=\"$tdid\">"
        if [ -f "$image" ]; then
            echo -n "<a href=\"$image\"/>"
            echo -n "<img src=\"$thumb\"/ width=100/>"
            echo "</a><br/>"
        fi
        echo "<a href=\"$fulltest\"/>log</a>"
        echo "</td>"
    done
    echo '</tr>'
done

echo '</table>'

done # test in $tests
