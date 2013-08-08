myxbackup
=========

simple, cron-triggered backup script for MySQL Databases using Percona xtrabackup

This is a simple Bash-Script trying to automate MySQL backups, using Persona's 
excellent [xtrabackup](http://www.percona.com/doc/percona-xtrabackup/2.1/).

It's intended to be run through CRON adding a crontab entry like this:

```
MAILTO=some.name@email.com
00 23 * * * root /path/to/script.sh -b /path/to/backups -d 4 -k 2 -u 4096 > /dev/null
```

This will create a full backup on day 4 (Option -d, 1 = Monday) of every week 
keeping 2 (Option -k) full weeks of backups in subdirectories of the path provided 
by option -b.

On all other days a incremental backup is done, if a corresponding full backup exists.

When passing option -u the the scipt tries to set the open files limit (ulimit -n),
which may be required, if you have many databases/tables - at least with Debian wheezy.

Old backups are automatically purged. 

In case something goes wrong, any email is sent to the Adress provided in the crontab.

Since I don't want to pass around MySQL login & password in the shell, this script 
(in fact it's innobackupex) relies on a .my.cnf in the home directory of the user 
executing the script, keeping the login-credentials.
It should look like this:

```INI
[client]
user="yourusername"
password="yourpassword"
```

This Script doesn't assist you in restoring backups. Read the innobackupex docs.

