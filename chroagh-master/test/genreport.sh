
# Collect list of tests
tests="`ls */results/*-test | sed -e 's|.*/\([^\.]*\)\..*|\1|' | sort -u`"
machines="`ls -d */status | sed -e 's|\([^/]*\)/.*|\1|' | sort -u`"

cat <<EOF
<html>
<head>
<style>
table.outer {
    border-collapse: collapse;
}
th.outer,td.outer {
    border: 1px solid black;
    border-spacing: 0px;
    padding: 0px;
}
th.outer {
    padding: 3px
}
td.outer {
    text-align: center;
}
table.inner {
    width: 100%;
    height: 100%;
    border-collapse: collapse;
}
td.inner {
    padding: 3px;
    text-align: center;
}
#PASSED {
    background-color: rgb(0, 255, 0);
}
#FAILED {
    background-color: rgb(255, 0, 0);
}
#UNKNOWN {
    background-color: rgb(128, 128, 128);
}
#BLANK {
    background-color: rgb(240, 240, 240);
}
</style>
</head>
<body>
EOF

pwd="`pwd`"
echo "<h1>`basename "$pwd"`</h1>"
echo "<div>Last updated: `TZ= date` (`date +"%H:%M:%S %Z"`)</div>"

ls "`dirname $0`/reports/"* 2>/dev/null | sort | while read -r report; do
    if [ -x "$report" -a "${report%\~}" = "$report" ]; then
        echo "Sourcing $report" 1>&2
        ( . "$report" )
    fi
done

echo '</body></html>'
