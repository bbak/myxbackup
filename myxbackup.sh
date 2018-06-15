#!/bin/bash
# vim: set ts=4 sw=4 sts=4 noai noet:
#
# Exit Codes:
# 0 - Backup succeeded
# 1 - Backup failed (for some reason).
# 3 - xtrabackup binary not found
# 4 - incremental failed, because the full backup was not found.
# 5 - unrecognized Option
# 6 - failed to set ulimit
# 7 - Backup directory already exists
# 
#
# See:
# http://www.percona.com/doc/percona-xtrabackup/howtos/recipes_ibkx_inc.html
# 
# Use e.g. this in a CRONtab:
# MAILTO=some.name@email.com
# 00 21 * * * root /path/to/script.sh -b /path/to/backups -d 4 -k 1 -u 4096 > /dev/null
#
#

#
# Execute a Backup, either "full" or "incremental"
#
function mk_backup() {
	local BACKUP_TYPE="$1"
	local BACKUP_LOG="$BASEDIR/innobackupex_$(date +'%Y%m%d').log"
	#
	# prepare params for xtrabackup binary
	#
	# full backup
	if [ "$BACKUP_TYPE" == "full" ]; then
		local BACKUP_PATH="$BASEDIR/$(date +'%Y%m%d')_full"
		echo $(format_message "Doing full backup in directory $BACKUP_PATH.")
	# incr backup
	elif [ "$BACKUP_TYPE" == "incremental" ]; then
		local BACKUP_PATH="$BASEDIR/$(date +'%Y%m%d')_incr"
		local FBDATE=$(get_last_full_backup_date)
		local FULLBACKUP_PATH="$BASEDIR/${FBDATE}_full"
		if [ ! -d $FULLBACKUP_PATH ]; then
			echo $(format_message "Cannot do incremental backup, because full backup directory ($FULLBACKUP_PATH) doesn't exist.") >&2
			return 4
		fi
		echo $(format_message "Doing incremental backup in directory $BACKUP_PATH as diff to $FULLBACKUP_PATH.")
	# param error
	else
		echo $(format_message "Illegal Backup Type") >&2
		return 1
	fi
	echo $(format_message "Logging to $BACKUP_LOG.")
	#
	# check if Backup Directory already exists
	#
	if [ -e "$BACKUP_PATH" ]; then
		echo $(format_message "Backup Directory \"$BACKUP_PATH\" already exists.") >&2
		return 7
	fi
	# Execute innnobackupex
	#
	# full backup
	if [ "$BACKUP_TYPE" == "full" ]; then
		$INNOBACKUPBINARY --backup --ssl-mode=DISABLED $IBOPT_RSYNC --no-timestamp --target-dir="$BACKUP_PATH" >"$BACKUP_LOG" 2>&1
	# incr backup
	elif [ "$BACKUP_TYPE" == "incremental" ]; then
		$INNOBACKUPBINARY --backup --ssl-mode=DISABLED $IBOPT_RSYNC --no-timestamp --target-dir="$BACKUP_PATH" --incremental-basedir="$FULLBACKUP_PATH" >"$BACKUP_LOG" 2>&1
	fi
	#
	# Handle result
	#
	RETVAL=$?
	if [ $RETVAL -ne 0 ]; then
		if [ $RETVAL -eq 9 ]; then
			echo $(format_message "xtrabackup cannot connect to the Database") >&2
		fi
		return $RETVAL
	fi
	# if there's a string like "120828 21:07:27  innobackupex: completed OK!" at the end of the file, the backup was successful.
	grep -E "^[0-9]+.*completed OK\!" <"$BACKUP_LOG" >/dev/null
	if [ $? -ne 0 ]; then
		# failed, write syslog message
		logger -p cron.err -t innobackup "Innobackup failed"
	else
		logger -p cron.info -t innobackup "Innobackup ok"
	fi
	return $?
}
#
# remove old backup-dirs if they exist
#
function rm_backups() {
	local FBDATE=$(get_last_full_backup_date)
	# go back in time
	local FBDATE_TO_DEL=$(date -d"$FBDATE $WEEKS_TO_KEEP weeks ago" +"%Y%m%d")
	local PATHS_TO_DEL
	PATHS_TO_DEL[0]="$BASEDIR/${FBDATE_TO_DEL}_full"
	local LOGS_TO_DEL
	LOGS_TO_DEL[0]="$BASEDIR/innobackupex_${FBDATE_TO_DEL}.log"
	if [ ! -d ${PATHS_TO_DEL[0]} ]; then
		echo $(format_message "No Full Backup found at ${PATHS_TO_DEL[0]}. Skipping deletion of Backups.")
		return 0
	fi
	local i=1
	while [ $i -lt 7 ]; do
		FBDATE_TO_DEL=$(date -d"$FBDATE_TO_DEL +1 days" +"%Y%m%d")
		if [ -d "$BASEDIR/${FBDATE_TO_DEL}_incr" ]; then
			PATHS_TO_DEL[$i]="$BASEDIR/${FBDATE_TO_DEL}_incr"
			if [ -e "$BASEDIR/innobackupex_${FBDATE_TO_DEL}.log" ]; then
				LOGS_TO_DEL[$i]="$BASEDIR/innobackupex_${FBDATE_TO_DEL}.log"
			fi
		else
			echo $(format_message "Missing incremental Backup at date ${FBDATE_TO_DEL}. Skipping deletion of Backups.") >&2
			return 1
		fi
		i=$[$i+1]
	done

	for DEL in "${PATHS_TO_DEL[@]}"
	do
		rm -R "$DEL"
		if [ $? -ne 0 ]; then
			logger -p cron.warn -t innobackup "Failed to delete $DEL"
		fi
	done
	for LOGDEL in "${LOGS_TO_DEL[@]}"
	do
		rm "$LOGDEL"
		if [ $? -ne 0 ]; then
			logger -p cron.warn -t innobackup "Failed to delete $LOGDEL"
		fi
	done
	echo $(format_message "Old Backups purged.")
	return 0
}
#
# get The date of the last full backup formatted as "%Y%m%d"
#
function get_last_full_backup_date() {
	local INCR_DATE_DIFF=$(($DAY_OF_WEEK - $DAY_OF_WEEK_FOR_FULL_BACKUP))
	if [ $INCR_DATE_DIFF -lt 0 ]; then
		INCR_DATE_DIFF=$(($INCR_DATE_DIFF + 7))
	fi
	local FBDATE=$(date -d"$INCR_DATE_DIFF days ago" +"%Y%m%d")
	echo $FBDATE
	return 0
}
#
# print usage of this script
#
function print_usage() {
    cat << EOF
    usage: $0 options

    This script runs xtrabackup according to options given.
    Currently only localhost can be backed up.
    This Script writes a log to the path passed in -b with filename innobackupex.log

    OPTIONS:
      -h           Show this message and exit.
      -b [path]    (required) Base-Path for Backup files. The directory has to exist. Please omit the trailing /
      -d [number]  (required) Day of Week for full backup (Monday = 1)
      -k [number]  (required) Number of Weeks to keep Backups. The Script always
                      deletes a full backup and all incremental ones, based on that.
                      Deletes are only done, if the (new) full backup succeeds.
      -u [number] (optional) if set tries to set ulimit -n to the provided value. May be needed in 
                      Debian (Wheezy+) if you have many Databases.
   
    NOTE:
      Since we don't want to pass the MySQL Username and Password around in the Shell (or Cron),
      this script requires a .my.cnf file in the Home-Directory of the user executing it.
      The contents of this file should be (at least) like this:

      [client]
      user="username"
      password="password"
 
EOF
}

function format_message() {
	echo "$(date +"%Y%m%d %T") $MY_HOSTNAME: $1"
}

function start_end_message() {
	local END_DT=$(date +"%Y%m%d %T")
	echo "Script started at $START_DT and ended at $END_DT"
}
#
# Main
#

#
# check existance of xtrabackup, exit 3 if not found
#
INNOBACKUPBINARY=$(which xtrabackup)
if [ ! -x "$INNOBACKUPBINARY" ]; then
	echo $(format_message "xtrabackup Binary not found. Cannot continue.") >&2
	exit 3
fi

#
# Some Variables
#
# DAY_OF_WEEK
DAY_OF_WEEK=$(date +"%u")
# Start Datetime
START_DT=$(date +"%Y%m%d %T")
# get the Hostname
if [ -x "/bin/hostname" ]; then
	MY_HOSTNAME=$(/bin/hostname --fqdn)
else
	MY_HOSTNAME=$(cat /etc/hostname)
fi
# check if rsync can be used
which rsync &>/dev/null
if [ $? -eq 0 ]; then
	IBOPT_RSYNC="--rsync"
else
	IBOPT_RSYNC=""
fi
#
# Variables for Options
#
BASEDIR=
DAY_OF_WEEK_FOR_FULL_BACKUP=
WEEKS_TO_KEEP=
ULIMIT_FILE=
#
# Parse Commandline options
#
while getopts ":u:hb:d:k:" FLAG; do
	case $FLAG in
		h)
			print_usage
			exit 0 ;;
		b) 
			BASEDIR=$OPTARG ;;
		d) 
			DAY_OF_WEEK_FOR_FULL_BACKUP=$OPTARG ;;
		k)
			WEEKS_TO_KEEP=$OPTARG ;;
		u)
			ULIMIT_FILE=$OPTARG ;;
		\?)
			echo "$0: unrecognized option" >&2
			exit 5 ;;
	esac
done
#
# validate passed Options
#
if [ -z $BASEDIR ] || [ -z $DAY_OF_WEEK_FOR_FULL_BACKUP ] || [ -z $WEEKS_TO_KEEP ];then
	print_usage
	exit 1
fi
if [ ! -d $BASEDIR ] || [ ! -w $BASEDIR ];then
	echo $(format_message "Directory $BASEDIR does not exist or is not writable.") >&2
	exit 1;
fi
if [ $DAY_OF_WEEK_FOR_FULL_BACKUP -gt 7 ] || [ $DAY_OF_WEEK_FOR_FULL_BACKUP -lt 1 ];then
	echo $(format_message "Option -d must be between 1 and 7") >&2
	exit 1
fi
if ! [ $WEEKS_TO_KEEP -ge 1 ] || ! [ $WEEKS_TO_KEEP -le 52 ]; then
	echo $(format_message "Option -k must be an integer between 1 and 52.") >&2
	exit 1
else
	# increment WEEKS_TO_KEEP by one
	WEEKS_TO_KEEP=$(($WEEKS_TO_KEEP + 1))
fi
#
# Set ulimit -n if Option -u was provided
#
if [ ! -z $ULIMIT_FILE ]; then
	echo $(format_message "Trying to set open files limit to $ULIMIT_FILE")
	ulimit -n $ULIMIT_FILE >/dev/null
	if [ $? -ne 0 ]; then
		echo $(format_message "Failed to set open files limit.") >&2
		exit 6
	else
		echo $(format_message "Ulimit set.")
	fi
fi
#
# Start full or incremental Backup
#
if [ $DAY_OF_WEEK -eq $DAY_OF_WEEK_FOR_FULL_BACKUP ]; then
	mk_backup full
	if [ $? -ne 0 ]; then
		echo $(format_message "xtrabackup full Backup failed.") >&2
		echo $(start_end_message) >&2
	else
		echo $(format_message "xtrabackup full Backup succeeded.")
		# check, if there are Backups to delete
		rm_backups
		if [ $? -ne 0 ]; then
			echo $(format_message "Deletion of Backups failed. However, a new full Backup was created.") >&2
		fi
		echo $(start_end_message)
	fi
	exit $?
else
	mk_backup incremental
	if [ $? -ne 0 ]; then
		echo $(format_message "xtrabackup incremental Backup failed.") >&2
		echo $(start_end_message) >&2
	else
		echo $(format_message "xtrabackup incremental Backup succeeded.")
		echo $(start_end_message)
	fi
	exit $?
fi
