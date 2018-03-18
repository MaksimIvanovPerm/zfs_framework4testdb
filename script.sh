#!/bin/bash
#-- Init -----------------------------------------------------
. /etc/profile.d/ora_env.sh
. /etc/rias/dba/rman.conf
. /etc/rias/dba/script.conf

#-- Global variables -----------------------------------------
LOCK_FILE=""
LOCK_FILE_DIR=${LOCK_FILE_DIR:-"/var/run/rias"}
LOG_FILE=${LOG_FILE:-"/var/log/rias/dba/script.log"}
CURRENT_LOG_FILE=$LOG_FILE.$$
SCRIPT_NAME=`basename $0`
CONSOLE_OUTPUT="Y"
TMP_FILE="/tmp/${SCRIPT_NAME}.txt.$$"
# Should be used only for sqlplusq-spool, in call under oracle os-account;
SQL_SPOOL_FILE="/tmp/${SCRIPT_NAME}_sqlspool.$$"

SNAPHSOT_NAME=""

RENEW_TEST_DB=0
SNAPSHOTING_TEST_DB=0
FLASHBACK_TEST_DB=0
DELETE_TEST_DB=0

TEST_DB_NAME=${TEST_DB_NAME:-"testdb0"}
RUNID=${RUNID:-`date +%s | tr -d [:cntrl:]`}

TIMEZONE_HOURS_DIFF=${TIMEZONE_HOURS_DIFF:-"0"}
OBSOLENCE_TIME=${OBSOLENCE_TIME:-"6"}


#-- Sub program ----------------------------------------------
log_info() {
local datetime=`date +%Y.%m.%d:%H.%M.%S`
local data_source=$2

if [ "$data_source" == "logfile" ]
then
 [ "$CONSOLE_OUTPUT" == "Y" ] && cat $1 | awk -v runid=$RUNID '{print runid": "$0}'
 cat $1 | awk -v runid=$RUNID '{print runid": "$0}' >> $CURRENT_LOG_FILE
else
 [ -e "$CURRENT_LOG_FILE" ] && echo "${RUNID}:${datetime}: $1" >> $CURRENT_LOG_FILE
 [ "$CONSOLE_OUTPUT" == "Y" ] && echo "${RUNID}:${datetime}: $1"
fi
}

usage() {
cat << __EOFF__
Use: `basename $0` [options]...
Maintenance operation with test db, which name is supposed to be setted as option "dbname" value;
For example: renew test db, make snapshot of the test db, rollback the test db to the given snapshot;
Script conf-file is: /etc/rias/dba/script.conf

Please note: all operation works with default test-db;
That means: operation try to work for db whose name is setted in conf-file or setted explicity defined by -n|--dbname
Arguments, which are required for short parameters, are required for long params too;
    -h, --help                  -- this help
     c, --stbcheck              -- Check how old standby-db is; 
    -q, --quiet                 -- Supress output to console, to log file only
    -l, --listsnapshot          -- list all snapshot(s), which was or were created for test-database
                                   If several snaps are, they'll be printed in order their creation time, ascending;
    -e, --erasesnap             -- Erase (destroy) given zfs-snapshot;
                                   You have to use full-name of the snapshot, in double-quotes;
                                   Run script with -l|--listsnapshot to obtain list of all zfs-snaps;
    -s, --snapshot              -- Make snapshot for test-db;
                                   If this parameter is used: you have to set name of shapshot, as the parameter value;
                                   You have to use double quotes, f.e.: -s "snap_201704261233"
                                   See also --dbname parameter;
    -f, --flashback             -- Flashback test-db to snapshot;
                                   If this parameter is used: you have to set name of shapshot, as the parameter value;
                                   You have to use double quotes, f.e.: -s "snap_201704261233"
                                   See also --dbname parameter;
                                   Please note: it's possible to create several snaps for the given db
                                   And you're able to flashback db to not the most recent snap, it's possible;
                                   But, in that case: all snaps, more recent than the target snap: will be destroyed finally, without prompting;
    -d, --deletedb              -- Delete test db;
                                   See also --dbname parameter;
    -r, --renew                 -- Create or replace test db, with name given in parameter dbname
                                   In other words: renew given db;
    -n, --dbname                -- Name of the processed test db, i.e.: ORACLE_SID;
                                   If you're going to use "_#$" chars then name should be specified in double-quote bracket;
                                   Note: the value should fit oracle-requitemets for ORACLE_SID value;
                                   See doc. for DB_NAME db-parameter.
                                   If this parameter is used, you have to specify value of the parameter
                                   If this parameter is not used, then the default test db name is: "testdb"  (see conf-file)
                                   The database name is case insensitive.

__EOFF__
 
}

myexit() {
local exit_code=$1

if [ -f "$TMP_FILE" ]
then
 rm -f $TMP_FILE
fi

# is's important: run-time log file shoud be processed namely at the end of subroutine
if [ -f "$CURRENT_LOG_FILE" ]
then
 cat $CURRENT_LOG_FILE >> $LOG_FILE
 rm -f $CURRENT_LOG_FILE
fi

exit $exit_code

}

rias_show_elapsedtime() {
    local s=${1:-0}
    local e=${2:-1}

    local ws=$(($e-$s))

    local hour=$(($ws/3600))
    local min=$((($ws - $hour*3600)/60))
    local sec=$(($ws - $hour*3600 - $min*60))

    echo "${hour}h ${min}m ${sec}s"
}


set_rias_rman_conf() {
if [[ "$1" == "Y" || "$1" == "y" || "$1" == "1" ]]
then
 output=`sed --in-place -e "s/RMAN_ENABLE=.*/RMAN_ENABLE=1/" /etc/rias/dba/rman.conf; cat /etc/rias/dba/rman.conf | egrep "^RMAN_ENABLE"`
else
 output=`sed --in-place -e "s/RMAN_ENABLE=.*/RMAN_ENABLE=0/" /etc/rias/dba/rman.conf; cat /etc/rias/dba/rman.conf | egrep "^RMAN_ENABLE"`
fi
log_info $output
}

cancel_standby_recover() {
local rc
local module="cancel_standby_recover"
local standby_sid="billing"
log_info "$module try to cancel recover in standby-db ${standby_sid}"

cat << __EOF__ > $TMP_FILE
conn / as sysdba
set echo on
select status from v\$instance;
alter database recover cancel;
exit;
__EOF__

[ -f "${SQL_SPOOL_FILE}" ] && rm -f "${SQL_SPOOL_FILE}"
stime=$(date +%s)
su -l oracle << __EOF__
[ ! -z "${standby_sid}" ] && export ORACLE_SID=${standby_sid}
$ORACLE_HOME/bin/sqlplus -S /nolog @$TMP_FILE 1>$SQL_SPOOL_FILE 2>&1
env | grep -i oracle | sort >> $SQL_SPOOL_FILE
__EOF__
etime=$(date +%s)
[ -f "$TMP_FILE" ] && rm -f $TMP_FILE
if [ -f "$SQL_SPOOL_FILE" ] 
then
 log_info "$SQL_SPOOL_FILE" "logfile"
 rm -f $SQL_SPOOL_FILE
fi
log_info "OK: standby-db recovery canceled; TIME:`rias_show_elapsedtime stime etime`"

}

shutdown_db() {
local rc
local module="shutdown_db"
local mode=${1:-"immediate"}
local db_name=$2

log_info "$module try to shutdown db with option: ${mode} `[ ! -z "${db_name}" ] && echo ${db_name}`"
cat << __EOF__ > $TMP_FILE
conn / as sysdba
set echo on
alter system set job_queue_processes=0 scope=memory;
shutdown $mode
exit;
__EOF__

[ -f "${SQL_SPOOL_FILE}" ] && rm -f "${SQL_SPOOL_FILE}"
stime=$(date +%s)
su -l oracle << __EOF__
[ ! -z "${db_name}" ] && export ORACLE_SID=${db_name}
$ORACLE_HOME/bin/sqlplus -S /nolog @$TMP_FILE 1>${SQL_SPOOL_FILE} 2>&1
__EOF__
etime=$(date +%s)
[ -f "$TMP_FILE" ] && rm -f $TMP_FILE
if [ -f "${SQL_SPOOL_FILE}" ]
then
 log_info "${SQL_SPOOL_FILE}" "logfile"
 rm -f ${SQL_SPOOL_FILE}
fi
log_info "$module OK: db ${ORACLE_SID} stopped; TIME:`rias_show_elapsedtime stime etime`"

}

startup_db () {
local rc
local module="startup_db"
local mode=${1:-""}
local db_name=$2

log_info "$module try to startup db with option: ${mode} `[ ! -z "${db_name}" ] && echo ${db_name}`"
cat << __EOF__ > $TMP_FILE
whenever sqlerror exit 1
whenever oserror exit 2
conn / as sysdba
set echo off
set pagesize 0
set linesize 128
startup $mode
select status from v\$instance;
show parameter db_name
Prompt alert-log:
select value||'/alert_${ORACLE_SID}.log' from v\$diag_info where name='Diag Trace';
exit;
__EOF__

[ -f "${SQL_SPOOL_FILE}" ] && rm -f "${SQL_SPOOL_FILE}"
stime=$(date +%s)
su -l oracle << __EOF__
[ ! -z "${db_name}" ] && export ORACLE_SID=${db_name}
$ORACLE_HOME/bin/sqlplus -S /nolog @$TMP_FILE 1>${SQL_SPOOL_FILE} 2>&1
env | grep -i oracle | sort >> ${SQL_SPOOL_FILE}
__EOF__
rc=$?
etime=$(date +%s)
[ -f "$TMP_FILE" ] && rm -f $TMP_FILE
if [ -f "${SQL_SPOOL_FILE}" ]
then
 log_info "${SQL_SPOOL_FILE}" "logfile"
 rm -f ${SQL_SPOOL_FILE}
fi
log_info "$module OK: db ${ORACLE_SID} started with exit code: $rc; TIME:`rias_show_elapsedtime stime etime`"
return $rc
}

isit_zfs_filesystem() {
local name=$1
if [ -z "$name" ] 
then 
 echo 1
else
 zfs list -H -o name -t filesystem | egrep -q  "^${name}$"; echo $?
fi
}

isit_zfs_snapshot() {
local name=$1
if [ -z "$name" ] 
then
 echo 1
else
 zfs list -H -o name -t snapshot | egrep -q  "^${name}$"; echo $?
fi
}

destroy_snapshot() {
local module="destroy_snapshot"
local name=$1
local rc
zfs destroy -R -p -v $name 1>$TMP_FILE 2>&1
rc=$?
if [ -f "$TMP_FILE" ] 
then
  log_info "$TMP_FILE" "logfile"
  rm -f $TMP_FILE
fi
log_info "$module exiting with exit code: $rc"
return $rc
}

destroy_filesystem() {
local module="destroy_filesystem"
local name=$1
local rc

zfs destroy -R -p -v $name 1>$TMP_FILE 2>&1
rc=$?
if [ -f "$TMP_FILE" ]
then
  log_info "$TMP_FILE" "logfile"
  rm -f $TMP_FILE
fi
return $rc
}

create_snapshot() {
local module="create_snapshot"
local rc
local snapshot_name=$1
local filesystem=$2
      snapshot_name=`echo ${filesystem}@${snapshot_name}`

local destroy_before_create=${3:-"N"}

log_info "$module Try to create snapshot $snapshot_name for $filesystem destroy_before_create option: ${destroy_before_create}"
if [[ $(isit_zfs_filesystem "${filesystem}" ) == "0" ]]
then
 log_info "$module OK: ${filesystem} exists and it's filesystem"
else
 log_info "$module ERROR: ${filesystem} doesn't exists and/or it isn't filesystem"
 return 1
fi

if [[ $(isit_zfs_snapshot "${snapshot_name}" ) == "0" ]]
then
 log_info "$module ERROR: snapshot with name ${snapshot_name} already exists"
 if [ "$destroy_before_create" == "Y" ]
 then
  log_info "$module destroy before create mode is allowed, destroying ${snapshot_name}"
  destroy_snapshot ${snapshot_name}
  [ "$?" -ne 0 ] && return 1
 else
  return 1
 fi
else
 log_info "$module OK: there isn't any snapshot with name ${snapshot_name}"
fi

log_info "$module OK: creating zfs-snapshot ${snapshot_name}"
zfs snapshot $snapshot_name 1>$TMP_FILE 2>&1
rc=$?
if [ "$rc" -eq 0 ]
then
 log_info "$module OK: snapshot created"
 zfs list -r $filesystem -t all > $TMP_FILE
 if [ -f "$TMP_FILE" ] 
 then 
   log_info "$TMP_FILE" "logfile"
   rm -f $TMP_FILE
 fi
else
 log_info "$module ERROR: "
 if [ -f "$TMP_FILE" ] 
 then 
  log_info "$TMP_FILE" "logfile"
  rm -f $TMP_FILE
 fi
fi
return $rc

}

create_clone() {
local module="create_clone"
local rc
local snapshot_name=$1
local filesystem=$2
      snapshot_name=`echo ${filesystem}@${snapshot_name}` # zfs-style name
local clone_path=$3                                       # mount-path for the new zfs-clone
local clone_name=`echo ${filesystem}/$4`                  # name of the new zfs-clone
local destroy_before_create=${5:-"N"}                     # what to do if the zfs-clone already exists

log_info "$module try to create clone ${clone_name} for ${snapshot_name} and mount it to ${clone_path}"

if [ -z "$clone_path" ] 
then
 log_info "$module ERROR: path for mount zfs-clone is empty"
 return 1
fi

if [ -d "$clone_path" ]
then
 log_info "$module ok: mount-path ${clone_path} exists and it's directory"
else
 log_info "$module WARN: mount-path for zfs-clone doesn't exist and/or it isn't directory; Try to create it"
 [ -f "$TMP_FILE" ] && rm -f $TMP_FILE
 mkdir -p $clone_path 1>$TMP_FILE 2>&1
 rc=$?
 log_info "$TMP_FILE" "logfile"
 [ "$rc" -ne 0 ] && return $rc
fi

if [[ $( isit_zfs_filesystem "${clone_name}" ) == "0" ]]
then
 log_info "$module ERROR: zfs-clone ${clone_name} already exists" 
 if [ "$destroy_before_create" == "Y" ]
 then
  log_info "$module destroy before create mode is setted, try to delete the zfs-clone"
  destroy_filesystem ${clone_name}
  rc=$?
  [ "$rc" -ne 0 ]  && return $rc
  log_info "$module zfs-clone ${clone_name} destroyed"
 else
  log_info "$module destroy before create mode is not setted, exiting with error"
  return 1
 fi
else
 log_info "$module zfs-clone ${clone_name} doesn't exist"
fi


log_info "$module creating zfs-clone ${clone_name}"
[ -f "$TMP_FILE" ] && rm -f $TMP_FILE
zfs clone -o mountpoint=$clone_path $snapshot_name ${clone_name} 1>$TMP_FILE 2>&1
rc=$?
log_info "$TMP_FILE" "logfile"
zfs list -r $filesystem -t all 1>$TMP_FILE 2>&1
log_info "$TMP_FILE" "logfile"
log_info "$module attempt to create zfs-clone is done, exiting with code ${rc}"
return $rc
 
}


check_if_pfile_exist() {
local rc
local module="check_if_pfile_exist"
local db_name="$1"
local pfile_name="$ORACLE_HOME/dbs/init${db_name}.ora"

if [ -z "$db_name" ]
then
 log_info "$module ERROR: arg with db name: is empty"
 return 1
fi

if [ ! -f "$pfile_name" ] 
then
 log_info "$module ERROR: pfile ${pfile_name} doesn't exits"
 log_info "$module please make it, for db with name ${db_name} before try to create this db"
 return 2
fi

log_info "$module ok pfile ${pfile_name} exist;"
return 0
}

pfile_edit() {
local rc
local module="pfile_edit"
local mode=$1 # edit or add
local parameter_name=$2
local parameter_value=$3
local pfile_name=$4

if [[ "$mode" != "edit" && "$mode" != "add" ]]
then
 log_info "$module you should call ${module} subprogram with add or edit option"
 return 1
fi

if [ -z "$parameter_name" ]
then
 log_info "$module parameter_name argument is empty"
 return 2
fi

if [ -z "$parameter_value" ]
then
 log_info "$module parameter_value argument is empty"
 return 3
fi

log_info "$module try to ${mode} ${parameter_name}=${parameter_value} in ${pfile_name}"
grep -q "${parameter_name}" ${pfile_name}
param_exits=$? # 0 - parameter exists in pfile; !0 - doesn't exists
[ "${param_exits}" -eq 0 ] && log_info "$module ${parameter_name} exists in pfile"
[ "${param_exits}" -ne 0 ] && log_info "$module ${parameter_name} doesn't exists in pfile"

output=""
if [ "$mode" == "edit" ] 
then
 if [ "${param_exits}" -eq 0 ]
 then
  log_info "$module editing"
  output=`sed --in-place -e "s/${parameter_name}=.*/${parameter_name}=${parameter_value}/" ${pfile_name}; cat ${pfile_name} | grep ${parameter_name}`
  log_info "$module ${output}"
  return 0
 else
  log_info "$module ${pfile_name} doesn't contain parameter ${parameter_name}"
  return 4
 fi
fi

if [ "$mode" == "add" ]
then
 if [ "${param_exits}" -ne 0 ]
 then
  log_info "$module adding"
  echo "${parameter_name}=${parameter_value}" >> ${pfile_name}
  output=`grep ${parameter_name}`
  log_info "$module ${output}"
  return 0
 else
  log_info "$module ${pfile_name} already contains parameter ${parameter_name}"
  return 5
 fi
fi

}

rename_db_files() {
local rc
local module="rename_db_files"
local stime
local etime
local new_path=$1
local db_name=$2

log_info "$module try to work with arg: ${new_path} `[ ! -z "${db_name}" ] && echo ${db_name}`"

if [ -z "$new_path" ]
then
 log_info "$module ERROR: new path for renaming files is empty string"
 return 1
fi

if [ ! -d "$new_path" ]
then
 log_info "$module ERROR: new path for renaming files is not directory"
 return 2
fi

log_info "$module ok, try to change path to files of the clone-db to: ${new_path}"

[ -f "$TMP_FILE" ] && rm -f $TMP_FILE
[ -f "${SQL_SPOOL_FILE}" ] && rm -f "${SQL_SPOOL_FILE}"

cat << __EOF__ > $TMP_FILE
whenever sqlerror exit 1
whenever oserror exit 2
conn / as sysdba
set pagesize 0
set echo off
set feedback off
set verify off
set linesize 256
set serveroutput on size unlimited

select database_role||' '||open_mode as "Database state" from v\$database;
Prompt Db file schema before renaming
Prompt Redo log files
select status||' '||MEMBER as "Redo-log file" from v\$logfile;
Prompt Data files
select status||' '||name as "DB files" from v\$datafile;
Prompt Temp files
select status||' '||NAME from  v\$tempfile;

Prompt Try to rename all those files

define new_path="$new_path"

declare
 cursor c1 is
 select MEMBER as full_name, regexp_substr(member,'[^/]+$') as file_name from v\$logfile
 union all
 select name as full_name, regexp_substr(name,'[^/]+$') as file_name from v\$datafile;

 cursor c2 is
 select name as full_name, regexp_substr(name,'[^/]+$') as file_name from v\$tempfile;

begin
 for i in c1
 loop
   dbms_output.put_line('alter database rename file '''||i.full_name||''' to ''&&new_path/'||i.file_name||'''');
   execute immediate 'alter database rename file '''||i.full_name||''' to ''&&new_path/'||i.file_name||'''';
 end loop;

 -- NID-00137
 for i in c2
 loop
  dbms_output.put_line('alter database tempfile '''||i.full_name||''' drop;');
  execute immediate 'alter database tempfile '''||i.full_name||''' drop';
 end loop;

end;
/

Prompt Db file schema after renaming
Prompt Redo log files
select status||' '||MEMBER as "Redo-log file" from v\$logfile;
Prompt Data files
select status||' '||name as "DB files" from v\$datafile;
Prompt Temp files
select status||' '||NAME from  v\$tempfile;

exit;
__EOF__

stime=$(date +%s)
su -l oracle << __EOF__
[ ! -z "${db_name}" ] && export ORACLE_SID=${db_name}
$ORACLE_HOME/bin/sqlplus -S /nolog @$TMP_FILE 1>${SQL_SPOOL_FILE} 2>&1
env | grep -i oracle | sort >> ${SQL_SPOOL_FILE}
__EOF__
rc=$?
etime=$(date +%s)

if [ -f "${SQL_SPOOL_FILE}" ]
then
 log_info "${SQL_SPOOL_FILE}" "logfile"
 rm -f ${SQL_SPOOL_FILE}
fi

log_info "$module exit code: $rc TIME:`rias_show_elapsedtime stime etime`"
return $rc
}

set_new_dbname() {
local rc
local module="set_new_dbname"
local db_name=$1
local opr_database=$2
local standby_db=$3
local sys_pwd

if [ -z "$db_name" ]
then
 log_info "$module ERROR: arg with new name for db - is empty"
 return 1
fi

sys_pwd=`su -l oracle -c "opr -r $opr_database sys | tr -d [:cntrl:]"`
if [ "$?" -ne 0 ]
then
 log_info "$module ERROR: can't read sys-pwd from opr with: opr -r ${opr_database} sys"
 return 2
fi

log_info "$module ok, try to set new db-name: ${db_name} `[ ! -z "${standby_db}" ] && echo "work under ORACLE_SID=${standby_db}"`"

[ -f "$SQL_SPOOL_FILE" ] && rm -f $SQL_SPOOL_FILE
su -l oracle << __EOF__
[ ! -z "${standby_db}" ] && export ORACLE_SID=${standby_db}
echo "Y" | $ORACLE_HOME/bin/nid target=SYS/${sys_pwd} dbname=${db_name} 1>$SQL_SPOOL_FILE 2>&1
#env | grep -i oracle | sort > $SQL_SPOOL_FILE
__EOF__
rc=$?
if [ -f "${SQL_SPOOL_FILE}" ]
then
 log_info "${SQL_SPOOL_FILE}" "logfile"
 rm -f ${SQL_SPOOL_FILE}
fi
log_info "$module exiting with code: $rc"
return $rc

}

create_spfile () {
local rc
local module="create_spfile"
local db_name=$1

if [ -z "$db_name" ]
then
 log_info "$module ERROR: arg with db-name: is empty"
 return 1
fi

log_info "$module try to create spfile for ${db_name}"
[ -f "${SQL_SPOOL_FILE}" ] && rm -f "${SQL_SPOOL_FILE}"
[ -f "$TMP_FILE" ] && rm -f $TMP_FILE

cat << __EOF__ > $TMP_FILE
whenever sqlerror exit 1
whenever oserror exit 2
conn / as sysdba
set echo on
Prompt create spfile from pfile='${ORACLE_HOME}/dbs/init${db_name}.ora';
create spfile from pfile='${ORACLE_HOME}/dbs/init${db_name}.ora';
exit;
__EOF__

su -l oracle << __EOF__
export ORACLE_SID=${db_name}
$ORACLE_HOME/bin/sqlplus -S /nolog @$TMP_FILE 1>${SQL_SPOOL_FILE} 2>&1
__EOF__
rc=$?

if [ -f "${SQL_SPOOL_FILE}" ]
then
 log_info "${SQL_SPOOL_FILE}" "logfile"
 rm -f ${SQL_SPOOL_FILE}
fi
log_info "$module exiting with code: $rc"
return $rc

}

activate_clone_db () {
local rc
local module="activate_clone_db"
local db_name=$1

if [ -z "$db_name" ]
then
 log_info "$module ERROR: arg with db-name: is empty"
 return 1
fi

log_info "$module try to activate ${db_name}"
[ -f "${SQL_SPOOL_FILE}" ] && rm -f "${SQL_SPOOL_FILE}"
[ -f "$TMP_FILE" ] && rm -f $TMP_FILE

cat << __EOF__ > $TMP_FILE
whenever sqlerror exit 1
whenever oserror exit 2
conn / as sysdba
set echo off
startup mount
select database_role||' '||open_mode from v\$database;
Prompt alter database activate physical standby database;
alter database activate physical standby database;
select database_role||' '||open_mode from v\$database;
alter database open;
shutdown immediate
startup 
exit;
__EOF__

su -l oracle << __EOF__
export ORACLE_SID=${db_name}
$ORACLE_HOME/bin/sqlplus -S /nolog @$TMP_FILE 1>${SQL_SPOOL_FILE} 2>&1
__EOF__
rc=$?

if [ -f "${SQL_SPOOL_FILE}" ]
then
 log_info "${SQL_SPOOL_FILE}" "logfile"
 rm -f ${SQL_SPOOL_FILE}
fi
log_info "$module exiting with code: $rc"
return $rc

}

exec_sql_script () {
local rc
local module="exec_sql_script"
local db_name=$1
local sql_script=$2

if [ -z "$db_name" ]
then
 log_info "$module ERROR: arg with db-name: is empty"
 return 1
fi

if [ ! -f "${sql_script}" ]
then
 log_info "$module ERROR: sql-script: ${sql_script} isn't file or not found"
 return 2
fi

log_info "$module ok try to run ${sql_script} for db ${db_name}"
[ -f "${SQL_SPOOL_FILE}" ] && rm -f "${SQL_SPOOL_FILE}"
[ -f "$TMP_FILE" ] && rm -f $TMP_FILE

su -l oracle << __EOF__
export ORACLE_SID=${db_name}
$ORACLE_HOME/bin/sqlplus /nolog @${sql_script} "${db_name}" 1>${SQL_SPOOL_FILE} 2>&1
__EOF__
rc=$?

if [ -f "${SQL_SPOOL_FILE}" ]
then
 log_info "${SQL_SPOOL_FILE}" "logfile"
 rm -f ${SQL_SPOOL_FILE}
fi
log_info "$module exiting with code: $rc"
return $rc


}

restart_listeners () {
local rc
local module="restart_listeners"

[ -f "$TMP_FILE" ] && rm -f $TMP_FILE
su -l oracle << __EOF__
$ORACLE_HOME/bin/lsnrctl stop 1>/dev/null 2>&1
$ORACLE_HOME/bin/lsnrctl stop mts_1522 1>/dev/null 2>&1
$ORACLE_HOME/bin/lsnrctl stop mts_1523 1>/dev/null 2>&1
$ORACLE_HOME/bin/lsnrctl start 1>/dev/null 2>&1
$ORACLE_HOME/bin/lsnrctl start mts_1522 1>/dev/null 2>&1
$ORACLE_HOME/bin/lsnrctl start mts_1523 1>/dev/null 2>&1
__EOF__

ps aux | grep tnsl 1>$TMP_FILE 2>&1
log_info "$TMP_FILE" "logfile"


}

process_tempts () {
local rc
local module="process_tempts"
local db_name=$1
local new_path=$2

if [ -z "$new_path" ]
then
 log_info "$module ERROR: new path for renaming files is empty string"
 return 1
fi


if [ -z "$db_name" ]
then
 log_info "$module ERROR: arg with db-name: is empty"
 return 1
fi

log_info "$module try to process temp-ts in db: ${db_name}"
[ -f "${SQL_SPOOL_FILE}" ] && rm -f "${SQL_SPOOL_FILE}"
[ -f "$TMP_FILE" ] && rm -f $TMP_FILE

cat << __EOF__ > $TMP_FILE
conn / as sysdba
set echo off
set feedback off
set linesize 128
set echo off
set verify off
set serveroutput on

define new_path="${new_path}"
declare
 v_temp_ts_name     varchar2(30);
 v_tempfile_count   number := 0;
begin
 SELECT dp.property_value 
 into v_temp_ts_name
 FROM database_properties dp 
 WHERE dp.property_name='DEFAULT_TEMP_TABLESPACE';
 
 dbms_output.put_line('Default temp ts names is: '||v_temp_ts_name);
 
 SELECT count(*)
 into v_tempfile_count
 FROM sys.dba_temp_files t
 WHERE t.tablespace_name=v_temp_ts_name;
 
 if v_tempfile_count = 0
 then
  dbms_output.put_line('Default temp ts names doesn''t has files');
  dbms_output.put_line('try to add tempfile');
  dbms_output.put_line('alter tablespace '||v_temp_ts_name||' add tempfile ''&&new_path/temp_01.dbf'' size 128M reuse autoextend on next 128M maxsize unlimited');
  execute immediate 'alter tablespace '||v_temp_ts_name||' add tempfile ''&&new_path/temp_01.dbf'' size 128M reuse autoextend on next 128M maxsize unlimited';
 else
  dbms_output.put_line('Default temp ts names contains some files');
 end if;
end;
/

exit;
__EOF__

su -l oracle << __EOF__
export ORACLE_SID=${db_name}
$ORACLE_HOME/bin/sqlplus -S /nolog @$TMP_FILE 1>${SQL_SPOOL_FILE} 2>&1
__EOF__
rc=$?

if [ -f "${SQL_SPOOL_FILE}" ]
then
 log_info "${SQL_SPOOL_FILE}" "logfile"
 rm -f ${SQL_SPOOL_FILE}
fi
log_info "$module exiting with code: $rc"
return $rc

}

create_orapw_file () {
local rc
local module="create_orapw_file"
local db_name=$1
local opr_database=$2
local sys_pwd

if [ -z "$db_name" ]
then
 log_info "$module ERROR: arg with db-name: is empty"
 return 1
fi

sys_pwd=`su -l oracle -c "opr -r $opr_database sys | tr -d [:cntrl:]"`
if [ "$?" -ne 0 ]
then
 log_info "$module ERROR: can't read sys-pwd from opr with: opr -r ${opr_database} sys"
 return 2
fi

log_info "$module ok, try to create orapwd-file for: ${db_name}"
[ -f "$TMP_FILE" ] && rm -f $TMP_FILE
$ORACLE_HOME/bin/orapwd file=$ORACLE_HOME/dbs/orapw${db_name} password="$sys_pwd" entries=10 force="Y" 1>$TMP_FILE 2>&1
rc=$?
chown oracle:oracle $ORACLE_HOME/dbs/orapw${db_name}
if [ -f "${TMP_FILE}" ]
then
 log_info "${TMP_FILE}" "logfile"
 rm -f ${TMP_FILE}
fi
log_info "$module exiting with code: $rc"
return $rc


}

turn_off_services () {
local rc
local module="turn_off_services"
local db_name=$1

if [ -z "$db_name" ]
then
 log_info "$module ERROR: arg with db-name: is empty"
 return 1
fi

log_info "$module work for ${db_name}"
[ -f "${SQL_SPOOL_FILE}" ] && rm -f "${SQL_SPOOL_FILE}"
[ -f "$TMP_FILE" ] && rm -f $TMP_FILE

cat << __EOF__ > $TMP_FILE
whenever sqlerror exit 1
whenever oserror exit 2
conn / as sysdba
set echo on
set head off
set pagesize 0
set linesize 128
Prompt alter system set service_names='' scope=memory;
alter system set service_names='' scope=memory;
Prompt alter system register;
alter system register;
show parameter db_name
exit;
__EOF__

su -l oracle << __EOF__
export ORACLE_SID=${db_name}
$ORACLE_HOME/bin/sqlplus -S /nolog @$TMP_FILE 1>${SQL_SPOOL_FILE} 2>&1
__EOF__
rc=$?
if [ -f "${SQL_SPOOL_FILE}" ]
then
 log_info "${SQL_SPOOL_FILE}" "logfile"
 rm -f ${SQL_SPOOL_FILE}
fi
log_info "$module exiting with code: $rc"
return 0

}

set_zfs_filesystem_properties() {
 local rc
 local module="set_zfs_filesystem_properties"
 local filesystem=$1
 local property_name=$2
 local property_value=$3

 if [ -z "$filesystem" ] 
 then
  log_info "$module ERROR: name of filesystem is empty"
  return 1
 fi

 if [ -z "$property_name" ]
 then
  log_info "$module ERROR: name of property is empty"
  return 2
 fi

 if [ -z "$property_value" ]
 then
  log_info "$module ERROR: value of property is empty"
  return 3
 fi
 
 log_info "$module try to set ${property_name}=${property_value} for ${filesystem}"
 [ -f "$TMP_FILE" ] && rm -f $TMP_FILE
 zfs set ${property_name}=${property_value} ${filesystem} 1>$TMP_FILE 2>&1
 rc=$?
 log_info "$TMP_FILE" "logfile"
 return $rc

}

zfs_get_properties() {
 local rc
 local module="zfs_get_properties"
 local filesystem=$1
 local property_name=$2
 local property_value=""

 #log_info "$module try to get value of ${property_name} of ${filesystem}"
 [ -f "$TMP_FILE" ] && rm -f $TMP_FILE
 zfs get -H ${property_name} ${filesystem} 1>$TMP_FILE 2>&1
 rc=$?
 if [ "$rc" -eq "0" ]
 then
  property_value=`cat $TMP_FILE | awk -F "\t" '{print $3}'`
  echo $property_value
 else
  echo "ERROR_GETTING_VALUE"
  #log_info "$TMP_FILE" "logfile"
 fi
}

do_renew_test_db() {
 # 
 local module="do_renew_test_db"
 local rc
 local snapshot_name="rnw_"${TEST_DB_NAME}
 local clone_name="cln_${snapshot_name}"
 local full_clone_name="${STANDBY_ZFS}/${clone_name}"

  restart_listeners
  check_if_pfile_exist "${TEST_DB_NAME}"
  if [ "$?" -eq 0 ]
  then
   log_info "$module ok pfile $ORACLE_HOME/dbs/init${TEST_DB_NAME}.ora exists "
  else
   log_info "$module exit due to absence of pfile for test db"
   return 1
  fi
 
  # in case it's second or more run: change db_name-parameter to the right value, as it's in source standby-db conf
  pfile_edit "edit" "db_name" "'${ORACLE_SID}'" "$ORACLE_HOME/dbs/init${TEST_DB_NAME}.ora"
  if [ "$?" -ne 0 ]
  then
   log_info "$module exit due to error at editing pfile for test db"
   return 1
  else
   log_info "$module ok pfile for test db edited"
  fi

  create_orapw_file "${TEST_DB_NAME}" "$OPR_DATABASE"
  if [ "$?" -ne 0 ]
  then
   log_info "$module exit due to error at creating orapw-file for ${TEST_DB_NAME}"
   return 2
  fi
 
  set_rias_rman_conf "0"
  cancel_standby_recover
  shutdown_db "immediate" "${ORACLE_SID}"

 # In case it's second or more run, that is: clone-db may be left started from previous time
 shutdown_db "abort" "${TEST_DB_NAME}"

 create_snapshot $snapshot_name $STANDBY_ZFS "Y"
 if [ "$?" -eq 0 ]
 then
  log_info "$module OK: snapshot $snapshot_name for $STANDBY_ZFS created"
 else
  log_info "$module ERROR: some error happened at attempt to create snapshot $snapshot_name for $STANDBY_ZFS"
  log_info "$module Try to start standby-db, enable rias-rman and exit"
  startup_db "mount"
  [ "$?" -ne 0 ] && log_info "$module exit due to startup error"
  set_rias_rman_conf "1"
  return 3
 fi

 create_clone  $snapshot_name $STANDBY_ZFS $CLONE_ZFS_MOUNTPOINT "${clone_name}" "Y"
 if [ "$?" -eq 0 ]
 then
  log_info "$module OK: zfs-clone for $snapshot_name for $STANDBY_ZFS was created"
 else
  log_info "$module ERROR: some error happened at attempt to create zfs-clone for $snapshot_name for $STANDBY_ZFS"
  log_info "$module Try to start standby-db, enable rias-rman and exit"
  startup_db "mount"
  [ "$?" -ne 0 ] && log_info "$module exit due to startup error"
  set_rias_rman_conf "1"
  return 4
 fi

 rc=0
 log_info "$module try to set properties for ${clone_name}"
 set_zfs_filesystem_properties "${full_clone_name}" "compression" "off"
 if [ "$?" -eq 0 ]
 then
  log_info "$module OK: property setted"
 else
  log_info "$module ERROR: setting property of ${clone_name} failed"
  log_info "$module Try to start standby-db, enable rias-rman and exit"
  startup_db "mount"
  [ "$?" -ne 0 ] && log_info "$module exit due to startup error"
  set_rias_rman_conf "1"
  return 5
 fi
 

 # try to startup with pfile which points to controlfile in the zfs-clone 
 # existence of clone-db pfile was checked above, by the check_if_pfile_exist subprogram
 startup_db "mount pfile='$ORACLE_HOME/dbs/init${TEST_DB_NAME}.ora'" "${ORACLE_SID}"
 if [ "$?" -ne 0 ] 
 then 
  log_info "$module exit due to clone-db tartup error"
  startup_db "mount"
  [ "$?" -ne 0 ] && log_info "$module can't start standy-db"
  set_rias_rman_conf "1"
  return 6
 else
  log_info "$module ok clone-db started with pfile=$ORACLE_HOME/dbs/init${TEST_DB_NAME}.ora"
 fi

 # try to rename data|redo|temp files of the clone-db
 rename_db_files "$CLONE_DB_FILE_PATH" "${ORACLE_SID}"
 if [ "$?" -ne 0 ]
 then
   log_info "$module exit due to error within rename files for test db"
   startup_db "mount"
   [ "$?" -ne 0 ] && log_info "$module can't start standy-db"
   set_rias_rman_conf "1"
   return 7
 else
   log_info "$module file rename: ok"
 fi

 # Change name of the clone-db
 set_new_dbname "${TEST_DB_NAME}" "$OPR_DATABASE" "${ORACLE_SID}"
 if [ "$?" -ne 0 ]
 then
  log_info "$module some error happened while setting new db name for clone-db"
  log_info "$module Try to start standby-db, enable rias-rman and exit"
  startup_db "mount"
  [ "$?" -ne 0 ] && log_info "$module can't start standy-db"
  set_rias_rman_conf "1"
  return 8
 fi

 # Set correct db_name value; We've just set it's value by nid-utility at db-files;
 pfile_edit "edit" "db_name" "'${TEST_DB_NAME}'" "$ORACLE_HOME/dbs/init${TEST_DB_NAME}.ora"
 if [ "$?" -ne 0 ]
 then
  log_info "$module can't set db_name='${TEST_DB_NAME}' in $ORACLE_HOME/dbs/init${TEST_DB_NAME}.ora"
  log_info "$module Try to start standby-db, enable rias-rman and exit"
  startup_db "mount"
  [ "$?" -ne 0 ] && log_info "$module can't start standy-db"
  set_rias_rman_conf "1"
  return 9
 fi

 rc=0
 create_spfile "${TEST_DB_NAME}"
 if [ "$?" -eq 0 ]
 then
   log_info "$module try to activate clone-standby"
   activate_clone_db "${TEST_DB_NAME}"
   rc=$?
   if [ "$rc" -eq 0 ]
   then
    log_info "$module well ok: standby-db was activated successfully"
    if [ -z "${AFTER_ACTIVATE_SQL}" ]
    then
     log_info "$module AFTER_ACTIVATE_SQL is empty"
    else
     log_info "$module AFTER_ACTIVATE_SQL=${AFTER_ACTIVATE_SQL}"
     exec_sql_script "${TEST_DB_NAME}" "$AFTER_ACTIVATE_SQL"
    fi
    process_tempts "${TEST_DB_NAME}" "$CLONE_DB_FILE_PATH"
   else
    log_info "$module error with activate clone-standby"
   fi
 else
  log_info "$module error within spfile creation for ${TEST_DB_NAME}"
 fi

 log_info "$module try to startup standby-db"
 startup_db "mount" "$ORACLE_SID"
 turn_off_services "$ORACLE_SID"
 set_rias_rman_conf "1"

 if [ "$rc" -eq 0 ]
 then
  log_info "$module ok, standby-db was activated successfully" 
  log_info "$module try to run post-operation script in clone-db"
  exec_sql_script "${TEST_DB_NAME}" "$POST_OPERATION_SQL"
 else
  log_info "$module standby-db activate failed, so we don't have test-db and due to it we don't have to run post-operations in it"
 fi

 log_info "$module done"
 return 0
}

list_snapshot () {
 local rc
 local module="list_snapshot"
 local db_name=$1

 if [ -z "$db_name" ]
 then
  log_info "$module ERROR: arg with db-name: is empty"
  return 1
 fi
 
 log_info "$module try to find clone-fs, to which snapshot(s) is|are supposed to belong" 
 zfs list -H -r ${STANDBY_ZFS} -t filesystem | grep "cln_rnw_${db_name}" -q
 if [ "$?" -ne 0 ]
 then
  log_info "$module there isn't any clone-fs, with name cln_rnw_${db_name}, so there isn't any snapshot(s) of it" 
  return 0
 fi

 log_info "$module ok, clone-fs with name cln_rnw_${db_name} exists; try to find out its snapshot(s)"
 log_info "$module Shapshot-data'll be order by shap-creation time, ascending"
 [ -f "$TMP_FILE" ] && rm -f $TMP_FILE
 zfs list -H -r ${STANDBY_ZFS}/cln_rnw_${db_name} -t snapshot -s creation 1>$TMP_FILE 2>&1
 if [ "$?" -ne 0 ]
 then
  log_info "$module can't get out data about snapshots:"
 else
  log_info "$module ok, data about snapshots were obtained successfully"
 fi

 if [[ `cat $TMP_FILE | wc -l` -eq 0 ]]
 then
  log_info "$module there isn't any snapshot for clone-fs cln_rnw_${db_name}"
 else
  log_info "$TMP_FILE" "logfile"
 fi

}

do_delete_test_db () {
 local rc
 local module="do_delete_test_db"
 local db_name=$1
 local snapshot_name="rnw_"${db_name}
 local filesystem=$2
       snapshot_name=`echo ${filesystem}@${snapshot_name}`


 if [ -z "$db_name" ]
 then
  log_info "$module ERROR: arg with db-name: is empty"
  return 1
 fi
 
 if [ "${db_name}" == "${ORACLE_SID}" ]
 then
  log_info "$module ERROR: you're trying to destroy master database, which are used for forming test-db"
  log_info "$module doing nothing, exiting"
  return 1
 fi

 log_info "$module ok: try to delete testdb with name: ${db_name}"
 log_info "$module try to stop it, without care about operation exit code"
 
 shutdown_db "abort" "${db_name}"
 log_info "$module try find and delete zfs-snapshot, $snapshot_name associated with ${db_name}" 
 
 if [[ $(isit_zfs_snapshot "${snapshot_name}" ) == "0" ]]
 then
  log_info "$module ok snapshot with name ${snapshot_name} exists"
  log_info "$module destroying it"
   destroy_snapshot ${snapshot_name}
   return $?
 else
  log_info "$module there isn't any snapshot with name ${snapshot_name}"
 fi
 
}

do_snapshot_test_db() {
 local rc
 local module="do_snapshot_test_db"
 local snap_name="$1"
 local filesystem="${STANDBY_ZFS}/cln_rnw_${TEST_DB_NAME}"
 local full_snap_name=`echo ${filesystem}@${snap_name} | tr -d [:cntrl:]`


 if [ -z "$snap_name" ]
 then
  log_info "$module ERROR: arg with snapshot-name: is empty"
  return 1
 else
  log_info "$module ok try to create snapshot ${snap_name} for test-db: ${TEST_DB_NAME}"
  log_info "$module fully-qualified name of the snap is: ${full_snap_name}"
 fi

 log_info "$module it's possible that the ${full_snap_name} already exists, try to check it"
 if [[ $(isit_zfs_snapshot "${full_snap_name}" ) == "0" ]]
 then
  log_info "$module you know what: the ${full_snap_name} already is; exiting with error"
  return 1
 else
  log_info "$module well ok: there isn't snapshot with name ${full_snap_name}"
  log_info "$module try to create it"
 fi

 log_info "$module it's unavoidable necessary to stop db ${TEST_DB_NAME}"
 shutdown_db "immediate" "${TEST_DB_NAME}"
 log_info "$module try to create snapshot ${snap_name}"
 create_snapshot "$snap_name" "$filesystem"
 rc=$?
 if [ "$rc" -ne "0" ]
 then
  log_info "$module some error(s) happened in create_snapshot subprogram, exit with error"
  return $rc
 fi

 log_info "$module snapshot ${full_snap_name} created, try to start test-db ${TEST_DB_NAME}"
 startup_db "" "${TEST_DB_NAME}"
 rc=$?
 if [ "$rc" -ne "0" ]
 then
  log_info "$module startup ${TEST_DB_NAME} failed"
  return $rc
 else
  log_info "$module done"
  return 0
 fi
}

do_flahsback_test_db () {
 local rc
 local module="do_snapshot_test_db"
 local snap_name="$1"
 local filesystem="${STANDBY_ZFS}/cln_rnw_${TEST_DB_NAME}"
 local full_snap_name=`echo ${filesystem}@${snap_name} | tr -d [:cntrl:]`
 local rollback_status=0

 if [ -z "$snap_name" ]
 then
  log_info "$module ERROR: arg with snapshot-name: is empty"
  return 1
 else
  log_info "$module value $snap_name was provided as snapshot name"
 fi

 log_info "$module fully-qualified name of the snap is supposed to be: ${full_snap_name}"
 log_info "$module try to check is ${full_snap_name} is exists and it's a snapshot"
 
 if [[ $(isit_zfs_snapshot "${full_snap_name}" ) == "0" ]]
 then
  log_info "$module ok: ${full_snap_name} is a snapshot of db ${TEST_DB_NAME}"
 else
  log_info "$module ERROR: ${full_snap_name} doesn't exist and/or it isn't snapshot, exit with error"
  return 2
 fi 

 log_info "$module well, ok: try to rollback filesystem of db ${TEST_DB_NAME} to ${full_snap_name}"
 log_info "$module it's unavoidable necessary to stop db ${TEST_DB_NAME}"
 shutdown_db "immediate" "${TEST_DB_NAME}"
 log_info "$module try to rollback to ${full_snap_name}"
 [ -f "$TMP_FILE" ] && rm -f $TMP_FILE
 zfs rollback -rRf ${full_snap_name} 1>$TMP_FILE 2>&1
 rollback_status=$?
 if [ "$rollback_status" -eq "0" ]
 then
  log_info "$module rollback is done"
 else
  log_info "$module rollback failed:"
  log_info "${TMP_FILE}" "logfile"
 fi
 log_info "$module try to startup db ${TEST_DB_NAME}"
 startup_db "" "${TEST_DB_NAME}"
 rc=$?
 if [ "$rc" -eq "0" ]
 then
  log_info "$module ok db ${TEST_DB_NAME} successfully started"
 else
  log_info "$module startup of db ${TEST_DB_NAME} failed"
 fi
 
 [ "$rollback_status" -ne "0" ] && return 3
 [ "$rc" -ne "0" ] && return 4
 return 0
 
}

function create_lock_file() {
 echo "$$" > $LOCK_FILE 2>/dev/null
 if [ "$?" -ne 0 ]
 then
  log_info  "$module ERROR: can not create lock-file: ${LOCK_FILE}; exit;"
  myexit 11
 fi
 log_info "$module OK: lock-file created"
}

function rm_lock_file() {
  local mod_str=$1
  [ -z $mod_str ] && mod_str=$module
  if [ -f "$LOCK_FILE" ]
  then
    rm -f $LOCK_FILE
    if [ "$?" -ne 0 ]
    then
      log_info  "$mod_str ERROR: can not delete lock-file: ${LOCK_FILE}"
    else
      log_info "$mod_str OK: Deleted lock-file: ${LOCK_FILE}"
    fi
  fi
}

function on_script_exit() {
  local module="on_script_exit"
  log_info "$module"
  startup_db "mount" ${ORACLE_SID}
  [ "$?" -ne 0 ] && log_info "$module can not start ${ORACLE_SID} standby-db"
  set_rias_rman_conf "1"
  rm_lock_file "EXIT trap"
}

function on_script_break() {
  local module="on_script_break"
  log_info "$module"
  startup_db "mount" ${ORACLE_SID}
  [ "$?" -ne 0 ] && log_info "$module can not start ${ORACLE_SID} standby-db"
  set_rias_rman_conf "1"
  rm_lock_file "BREAK trap"
}

function on_script_hup() {
  local module="on_script_hup"
  log_info "$module"
  startup_db "mount" ${ORACLE_SID}
  [ "$?" -ne 0 ] && log_info "$module can not start ${ORACLE_SID} standby-db"
  set_rias_rman_conf "1"
  rm_lock_file "HUP trap"
}

function on_script_quit() {
  local module="on_script_hup"
  log_info "$module"
  startup_db "mount" ${ORACLE_SID}
  [ "$?" -ne 0 ] && log_info "$module can not start ${ORACLE_SID} standby-db"
  set_rias_rman_conf "1"
  rm_lock_file "QUIT trap"
}

function on_script_term() {
  local module="on_script_term"
  log_info "$module"
  startup_db "mount" ${ORACLE_SID}
  [ "$?" -ne 0 ] && log_info "$module can not start ${ORACLE_SID} standby-db"
  set_rias_rman_conf "1"
  rm_lock_file "TERM trap"
}

standby_obsolence_check()
{
local module="standby_obsolence_check"

if [[ $RMAN_ENABLE = "0" ]];
then
 log_info "$module RMAN_ENABLE=${RMAN_ENABLE}"
 return 4
fi;

log_info "$module TIMEZONE_HOURS_DIFF: $TIMEZONE_HOURS_DIFF"
log_info "$module OBSOLENCE_TIME: $OBSOLENCE_TIME"

cat << __EOF__ > $TMP_FILE
conn / as sysdba
set verify off
set head off
select to_char(obsolence_time,'09.999') from (select 24*(sysdate-NEXT_TIME)-$TIMEZONE_HOURS_DIFF as obsolence_time from v\$archived_log where RESETLOGS_CHANGE#=(select RESETLOGS_CHANGE# from v\$database) and APPLIED='YES' order by SEQUENCE# desc) where rownum=1;
exit;
__EOF__

su -l oracle << __EOF__
export ORACLE_SID=${ORACLE_SID}
$ORACLE_HOME/bin/sqlplus -S /nolog @$TMP_FILE 1>${SQL_SPOOL_FILE} 2>&1
__EOF__

stb_obsolence=$(cat ${SQL_SPOOL_FILE} | egrep -o "[0-9]+.[0-9]+")


cat << __EOF__ > $TMP_FILE
conn / as sysdba
set verify off
set head off
select open_mode from v\$database;
exit;
__EOF__

su -l oracle << __EOF__
export ORACLE_SID=${ORACLE_SID}
$ORACLE_HOME/bin/sqlplus -S /nolog @$TMP_FILE 1>${SQL_SPOOL_FILE} 2>&1
__EOF__

stb_state=$(cat ${SQL_SPOOL_FILE} | tr -d [:space:] | tr -d [:cntrl:])
log_info "$module stb_obsolence: ${stb_obsolence}"
log_info "$module stb_state: ${stb_state}"

if [[ ! "$stb_obsolence" =~ ^[0-9]+\.[0-9]+$ ]]
then
 log_info "$module can not determ obsolence"
 return 1
elif [ `echo $stb_obsolence'>'$OBSOLENCE_TIME | bc -l` -eq 1 ]
then
 log_info "$module standby-db is too old"
 return 2
fi

if [[ "$stb_state" != "MOUNTED" ]]
then
 log_info "$module standby-db is not opened in MOUNTED state"
 return 3
fi

log_info "$module done"
}

#-- Main program ---------------------------------------------
#set signal handlers
#trap on_script_exit EXIT
#trap for ctrl+c
trap on_script_break INT
trap on_script_hup HUP
trap on_script_quit QUIT
trap on_script_term TERM

module="main"
if [ ! -e "$LOG_FILE" ] 
then
 touch $LOG_FILE 1>/dev/null 2>&1
 if [ "$?" -ne 0 ] 
 then 
  echo "ERROR: can not create log file: ${LOG_FILE}; exit;"
  myexit 1
 fi
fi


touch $CURRENT_LOG_FILE 1>/dev/null 2>&1
if [ "$?" -ne 0 ] 
then 
 echo "ERROR: can not create run-time log file: ${CURRENT_LOG_FILE}; exit;"
 myexit 2
fi

CONSOLE_OUTPUT="N"
log_info "$module OK, try to start as: ${SCRIPT_NAME} $*"
CONSOLE_OUTPUT="Y"

if [ "$#" -eq 0 ]
then
 log_info "$module ERROR: you should call this script with, at least, one parameter"
 log_info "$module See help by ${SCRIPT_NAME} -h"
 myexit 0
fi

options=$(getopt -o cldhqrn:s:f:e: --long stbcheck,listsnapshot,deletedb,help,quiet,renew,dbname:,snapshot:,flashback:erasesnap: -- "$@")
if [ "$?" -ne 0 ]
then
 log_info "$module ERROR: Some error happened while arguments of script-call were parsed;" 
 log_info "$module See help by ${SCRIPT_NAME} -h"
 myexit 3
fi

#CONSOLE_OUTPUT="N"
#log_info "$module getopt output is: ${options}"
#CONSOLE_OUTPUT="Y"

eval set -- "$options"

FLASHBACK_TEST_DB=0
SNAPSHOTING_TEST_DB=0
RENEW_TEST_DB=0
DELETE_TEST_DB=0
LIST_SNAPSHOT=0
ERASE_SNAPSHOT=0
STB_CHECK=0

while [ ! -z "$1" ]
do
  case "$1" in
    -h|--help) usage; myexit 0
               ;;
    -c|--stbcheck) STB_CHECK=1
               ;;
    -r|--renew) RENEW_TEST_DB=1
                ;;
    -q|--quiet) CONSOLE_OUTPUT="N";
                log_info "$module quiet mode setted;" 
               ;;
    -n|--dbname) shift
                 TEST_DB_NAME=$1
                 ;;
    -s|--snapshot) shift 
                   SNAPHSOT_NAME=$1
                   SNAPSHOTING_TEST_DB=1
                  ;;
    -f|--flashback) shift
                    SNAPHSOT_NAME=$1
                    FLASHBACK_TEST_DB=1 
               ;;
    -e|--erasesnap) shift
                    SNAPHSOT_NAME=$1
                    ERASE_SNAPSHOT=1
               ;;
     -d|--deletedb) DELETE_TEST_DB=1
               ;;
     -l|--listsnapshot) LIST_SNAPSHOT=1
               ;;
     *) break  ;;
  esac

  shift
done


log_info "$module started with spid: $$"
log_info "$module WORK_ENABLE=${WORK_ENABLE}"

# Try to check: if several different operation were ordered at once
if [ "$((STB_CHECK+ERASE_SNAPSHOT+FLASHBACK_TEST_DB+SNAPSHOTING_TEST_DB+RENEW_TEST_DB+DELETE_TEST_DB+LIST_SNAPSHOT))" -ne 1 ]
then
 log_info "$module ERROR: you ordered to execute no one, or several operation at the same time; It's not possible;"
 log_info "$module Please note: snapshot-related operation supposed to be done only after test db have been created;"
 log_info "$module Please specify only one operation"
 myexit 4
fi

[ -f "$TMP_FILE" ] && rm -f $TMP_FILE
if [ "$RIGHT_PATH" != "" ]
then
 export PATH=$RIGHT_PATH
else
 log_info "$module WARN: env-var PATH is not setted explicity by these script;"
fi

log_info "$module script is running under `whoami`, env is:"
env | sort > $TMP_FILE
log_info "$module current zfs-schema is:"
zfs list -t all -s creation >> $TMP_FILE
log_info "$TMP_FILE" "logfile"


if [ "$STB_CHECK" -eq 1 ]
then
 log_info "$module check how modern is standby-db"
 standby_obsolence_check
 rc=$?
 myexit $rc
fi

if [ "$LIST_SNAPSHOT" -eq 1 ]
then
 log_info "$module ok, listing of snapshot for testdb ${TEST_DB_NAME} required"
 list_snapshot ${TEST_DB_NAME}
 myexit 0
fi

if [ "$ERASE_SNAPSHOT" -eq 1 ]
then
 log_info "$module ok, destroying snapshot ${SNAPHSOT_NAME} for testdb ${TEST_DB_NAME} required"
 if [[ $(isit_zfs_snapshot "${SNAPHSOT_NAME}" ) == "0" ]]
 then
  log_info "$module ok: ${SNAPHSOT_NAME} exists and it's snapshot; try to destroy it"
  destroy_snapshot "${SNAPHSOT_NAME}"
  myexit $?
 else
  log_info "$module ERROR: ${SNAPHSOT_NAME} isn't snapshot and/or doesn't exits"
  myexit 1
 fi
fi

if [ "$WORK_ENABLE" == "1" ]
then
 log_info "$module ok work is permitted by configuration;"
else
 log_info "$module Work is not enabled by configuration: WORK_ENABLE=$WORK_ENABLE"
 myexit 1
fi


#Try to check: if name of test db is valid
#echo $TEST_DB_NAME
if [[ "${#TEST_DB_NAME}" -gt 8 || "${#TEST_DB_NAME}" -eq 0 ]]
then
 log_info "$module ERROR: length of name of the test db should be in range 1:8 characters"
 myexit 5
fi

if [[ ! "$TEST_DB_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_#$]+$ ]]
then
 log_info "$module ERROR: allowed characters for db-name are: [a-zA-Z0-9_#$] and _#$ should not be prefix char."
 myexit 6
fi


log_info "$module try to reag value of mountpoint property of $STANDBY_ZFS filesystem"
ORIGIN_ZFS_MOUNTPOINT=$(zfs_get_properties "$STANDBY_ZFS" "mountpoint")
ORIGIN_ZFS_MOUNTPOINT=${ORIGIN_ZFS_MOUNTPOINT%/}
if [ "${ORIGIN_ZFS_MOUNTPOINT}" == "ERROR_GETTING_VALUE" ]
then
 log_info "$module ERROR: can't get out value of mountpoint property for $STANDBY_ZFS"
 myexit 7
else
 log_info "$module ok, ORIGIN_ZFS_MOUNTPOINT=${ORIGIN_ZFS_MOUNTPOINT}"
fi

if [ -z "${ORIGINAL_DB_SID}" ]
then
 log_info "$module ERROR SID of original db is not setted, exiting"
 myexit 8
else
 log_info "$module ok SID of original db is: ${ORIGINAL_DB_SID}"
fi

log_info "$module Value: ${TEST_DB_NAME} will be used as name of the processed test db"
if [ -z "$CLONE_ZFS_MOUNTPOINT" ]
then
 CLONE_ZFS_MOUNTPOINT=${ORIGIN_ZFS_MOUNTPOINT}"/"${TEST_DB_NAME}
 CLONE_ZFS_MOUNTPOINT=${CLONE_ZFS_MOUNTPOINT%/}
 log_info "$module calculated value: CLONE_ZFS_MOUNTPOINT=${CLONE_ZFS_MOUNTPOINT}" 
else
 CLONE_ZFS_MOUNTPOINT=${CLONE_ZFS_MOUNTPOINT%/}
 log_info "$module conf-setted value: CLONE_ZFS_MOUNTPOINT=${CLONE_ZFS_MOUNTPOINT}"
fi

if [ -z "$CLONE_DB_FILE_PATH" ]
then
 log_info "$module ADDITIONAL_FOLDERS: ${ADDITIONAL_FOLDERS}"
 if [ -z "${ADDITIONAL_FOLDERS}" ]
 then
  CLONE_DB_FILE_PATH=${CLONE_ZFS_MOUNTPOINT}"/"${ORIGINAL_DB_SID}
 else
  CLONE_DB_FILE_PATH=${CLONE_ZFS_MOUNTPOINT}"/"${ADDITIONAL_FOLDERS}
 fi
 log_info "$module calculated value: CLONE_DB_FILE_PATH=${CLONE_DB_FILE_PATH}"
else
 log_info "$module conf-setted value: CLONE_DB_FILE_PATH=${CLONE_DB_FILE_PATH}"
fi

#Try to check lock-dir.
# And, if directory is ok - try to create lock-file name
if [[ -d "$LOCK_FILE_DIR" && -w "$LOCK_FILE_DIR" ]]
then

 log_info "$module OK: directory for lock-file exists and writable;"
 if [ "$FLASHBACK_TEST_DB" -eq 1 ] 
 then
   LOCK_FILE=${LOCK_FILE_DIR}"/script_flshback_"${TEST_DB_NAME}".lck"
   log_info "$module flashback to snapshot operation is demended by script args"
 elif [ "$SNAPSHOTING_TEST_DB" -eq 1 ]
 then
  LOCK_FILE=${LOCK_FILE_DIR}"/script_snpsht_"${TEST_DB_NAME}".lck"
  log_info "$module snapshot operation is demanded by script args"
 elif [ "$RENEW_TEST_DB" -eq 1 ]
 then
  LOCK_FILE=${LOCK_FILE_DIR}"/script_rnw_"${TEST_DB_NAME}".lck"
  log_info "$module renew operation is demanded by script args"
 elif [ "$DELETE_TEST_DB" -eq 1 ]
 then
  LOCK_FILE=${LOCK_FILE_DIR}"/script_dlt_"${TEST_DB_NAME}".lck"
  log_info "$module delete test db operation is demanded by script args"
 fi
 log_info "$module lock-file name is: ${LOCK_FILE}" 

else
 log_file "ERROR: object ${LOCK_FILE_DIR} is supposed to be writable directory for lock-file;"  
 log_file "But it is not directory and/or not writable; exit;"
 myexit 9
fi

# Try to set up LOCK_FILE
if [ -f "$LOCK_FILE" ]
then
 lock_pid=`cat "$LOCK_FILE" | tr -d [cntrl]`
 exist_pid=`ps aux | grep "${SCRIPT_NAME}" | grep -v 'grep' | awk '{print $2;}'`

 if [ "x$exist_pid" = "x$lock_pid" ]
 then
  log_info "$module ERROR: LOCK_FILE: ${LOCK_FILE} already exists;"
  log_info "$module SPID from ${LOCK_FILE} is: $lock_pid"
  myexit 10
 else
  log_info "$module WARN: LOCK_FILE: ${LOCK_FILE} already exists but process not found."
  log_info "$module release lock and recreate"
  create_lock_file
 fi
else
 create_lock_file
fi

#sleep 60

 if [ "$FLASHBACK_TEST_DB" -eq 1 ]
 then
  do_flahsback_test_db "${SNAPHSOT_NAME}"
  rc=$?
  if [ "$rc" -ne 0 ] 
  then
    rm_lock_file "$module"
    myexit $rc
  fi
 elif [ "$SNAPSHOTING_TEST_DB" -eq 1 ]
 then
  do_snapshot_test_db "${SNAPHSOT_NAME}"
  rc=$?
  if [ "$rc" -ne 0 ] 
  then
    rm_lock_file "$module"
    myexit $rc
  fi
 elif [ "$RENEW_TEST_DB" -eq 1 ]
 then
  do_renew_test_db
  rc=$?
  if [ "$rc" -ne 0 ]
  then
   rm_lock_file "$module"
    myexit $rc
  fi
 elif [ "$DELETE_TEST_DB" -eq 1 ]
 then
  do_delete_test_db "${TEST_DB_NAME}" "$STANDBY_ZFS"
  rc=$?
  if [ "$rc" -ne 0 ]
  then 
   rm_lock_file "$module"
   myexit $rc
  fi
 fi

log_info "$module exiting with rc=0"
rm_lock_file "$module"

myexit 0
