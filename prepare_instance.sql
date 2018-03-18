set echo on
set serveroutput on
WHENEVER SQLERROR EXIT FAILURE
define dbname="&1"

conn / as sysdba
prompt Start preparing instance
exec sys.dbms_system.ksdwrt(2, To_Char(SYSDATE,'yyyy.mm.dd:hh24:mi:ss')||' Start preparing instance at &&dbname');
exec sys.dbms_system.ksdwrt(2, To_Char(SYSDATE,'yyyy.mm.dd:hh24:mi:ss')||' setting global_name to &&dbname..testing.example.com');

alter database rename global_name to &&dbname..testing.example.com;

WHENEVER SQLERROR CONTINUE
shutdown immediate
startup mount

set echo on
set serveroutput on
WHENEVER SQLERROR EXIT FAILURE


alter database noarchivelog;
alter database no force logging;
alter database open;

prompt Done with &&dbname
exec sys.dbms_system.ksdwrt(2, To_Char(SYSDATE,'yyyy.mm.dd:hh24:mi:ss')||' Done with &&dbname');
exit;
