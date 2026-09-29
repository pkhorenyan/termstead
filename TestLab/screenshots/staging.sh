cd
p='ubuntu@staging-app:~$ '
printf '%s%s\n' "$p" 'uptime'
echo ' 14:31:52 up 27 days,  6:40,  1 user,  load average: 0.08, 0.05, 0.01'
PS1="$p" exec sh -i
