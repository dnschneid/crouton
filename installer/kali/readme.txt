You will probably want to add the 'non-free' section to your kali repos.  

Adding non-free in the existing lines in /etc/apt/sources.list should work.  The sources should then look like the ones below when you are done.

deb http://http.kali.org stable non-free main contrib
deb-src http://http.kali.org stable non-free main contrib
