1. [What is zfs_framework4testdb](#zfs_framework4testdb)
2. [What are required for the bash script in order to force it work](#what-are-required-for-the-bash-script-in-order-to-force-it-work)
3. [How it works, the idea:](#how-it-works-the-idea)
4. [Couple words about the bash script itself](#couple-words-about-the-bash-script-itself)
5. [How to start it all in the work](#how-to-start-it-all-in-the-work)

### zfs_framework4testdb
This project contains bash-shell script, which name is, simply: "script.sh";
The shell script allows you to perfom some operations with test database: (re)create it, make db snapshot, rollback test-db to previously maked snapshot, drop snapshot, drop test-db;
If your server has enough resources (first of all: RAM) you are able to maintain several test-db at the server simultaneously;
About database: let's consider what I'm talking about oracle xe database, here and later;
Suppose that you have, somewhere, archivelog-moded oracle-xe db.
Let's call the database as main database;
And, for some reason, you want to get test-database for the main db, somewhere else, on physically separated place;
Of course there're several ways to build the test db.
First way which probably flash across you mind: to use rman-backup of the main db to build the test db;
But it's: 
1. not easy for all, you have to be well enough in rman-related work
2. and you have to be well enough in bash-shell scripting, in case if you'll want to save your time and to script this routine.
3. it takes the same amount of disk space, at test-server site as the main db at their site
4. and test-db, which was produced in such way will become more obsolete as the time passed away sine it was produced;
There is only one way to refresh such test-db: rebuild it again from rman-backup and get into deal more actual test-db;
5. But it takes time; While restore-recover phase of work take their time: you haven't test-db; And waht if restore-recover phase will fail.

But this aren't all headackes;
Sooner or later part of your developers says somewhat like: "listen, we don't know what could be with table data at the end of our test. But we want to see it. And if we'll understand the result of test is wrong: we want immediatly rollback test db in state just before test; And, btw, we want test db with actual table data;"
And another part of developers, at te same time, says somewhat like: "listen, we are going to perfom very important tests right now; So we need the test db exclusively. And, btw, we want test db with actual table data;"
So, actually, you have to provide your teams of develeopers with:
1. ability to create and|or recreate(renew) their own test db, just when they want to do it
2. ability to flashback test db to state before test, without bying oracle ee (flashback database); and again: it's much better it their do it by himself, without dba;
3. and you are better to do it without building huge amount of servers for test-databases.
That is: without bying huge amount of disk space, cpu-cores, memrory and etc.


### what are required for the bash script in order to force it work
Of couse the bash script doesn't do all this stuff by itself;
It's only top iceberg;
You have to prepare a lot of parts and items under it properly:
1. You have to prepare OS: it should be an OS on which you're able to install oracle db. 
So OS shoud be prepared properly for installing on it oracle database. In short I mean here that:
   1. You have to properly prepeare `/etc/sysctl.conf` (or its analogue in your OS) 
   1. You have to create oracle-related os-users, groups, folders structire, set properly permissons-modes for it
   1. You have to set properly OS-limits for `oracle` OS-accounts
   1. You have to prepare `pfile` and|or `spfile` for oracle db and check: if instance if the database start successfully; 
Running a bit ahead I have to note: there're, at least, two oracle-instance at the server; 
   1. You have to configure `/etc/oratab`, `$TNS_AMIN/(listener|sqlnet|tnsnames).ora` properly;
You have to do something for properly init env for `oracle` OS account: I mean - init `$ORACLE_(SID|HOME)` and `$TNS_AMIN` env vars, at least;
   1. You hve to check: if there oracle-listener (or listeners, if you need more than one) starts up successfully.
And oracle instance makes registration of their services in the listener (or listeneres) successfully.
2. zfsonlinux: you have to install it on the given OS as well. And it should work properly;
3. You have to provide read-access, from test-db machine to the rman-backup of the main db; 
For example you can use nfs-disk for sharing those backups between site with main db, and site with test db;
4. You better have `opr` utility for storing and getting passwords of database account;
It's very usefull and right utility, it allows you not to hardcode password(s) inside your schell-scripts;
You may find it [here](https://sourceforge.net/projects/opr/)

### How it works, the idea:
Now, collecting everything together: how, conceptually, it works
1. On the test machine you make zfs-pool;
Inside it you make several zfs-filesystem.
For example:
```shell
sudo -u root -i
zpool create -f -m /db oradata  /dev/sdb
zpool set autoexpand=on oradata
zpool list
zpool status -v

cd /db/
mkdir u11
mkdir u13

zfs create oradata/u11 -o mountpoint=/db/u11
zfs create oradata/u13 -o mountpoint=/db/u13

zfs set acltype=posixacl oradata/u11
zfs set atime=off oradata/u11
zfs set recordsize=8K oradata/u11
zfs set compression=gzip-1 oradata/u11
zfs set logbias=throughput oradata/u11

zfs set acltype=posixacl oradata/u13
zfs set atime=off oradata/u13
zfs set recordsize=8K oradata/u13
zfs set compression=off oradata/u13
zfs set quota=50G oradata/u13
zfs set logbias=throughput oradata/u13
```
Here, it's supposed that test-db parameter `db_block_size` setted in value `8K`;

2. On the test-db site you build copy of your main db; 
Please note: I don't state that you should do all this things, which mentioned below, with your database.
I just say that it's technically possible. 
Suppose that on the test-db site all conditions for running oracle-db: are the same, as at the main-db site.
Oracle software version and edition, set of patches in it, OS, OS-users if their id, file|folder schema in OS and etc.
In that case, for example, you may obtain this copy by the following scenario:
  1. Prepare, at site of the main-db, `physical standby` controlfile:
```shell
echo "alter database create physical standby controlfile as '/home/oracle/ctrl.bin' reuse;" | $ORACLE_HOME/bin/sqlplus -S "/ as sysdba"
mv -v ./ctrl.bin <path to the nfs-disk>

$ORACLE_HOME/bin/rman target "/" << __EOFF__
crosscheck copy of controlfile;
delete noprompt force expired copy;
exit;
__EOFF__
```
  2. Then, at test-db site, you have to start oracle-instance, restore to it image of newly created controlfile and mount db:
```shell
echo "startup force nomount;" | $ORACLE_HOME/bin/sqlplus -S "/ as sysdba"
echo "restore controlfile from <path to the nfs-disk/ctrl.bin>;" | $ORACLE_HOME/bin/rman target "/"
echo "alter database mount standby database;" | $ORACLE_HOME/bin/sqlplus -S "/ as sysdba"
```
  3. Then with help of rman-backup, which are readable on the test-db machine: restore all files of fb file-schema;
Please note: here, you have to place all db-files, of the test-db, in one zfs filesystem, with compression.
In terms of statements in the previous point it's: `oradata/u13` filesystem
You're able to use database parameter `db_file_name_convert` for setting rules of datafile-path remapping in controlfile(s) of the test-db
Also you have to place, in the same zfs-filesystem (and it would be better: in the same folder): controlfile and redo-file of the newly created db;
Your goal, after all - to get this db in mount state, and all file in db file schema should be in online status;
3. Next: somehow you start the process of constantly recover ot the test-db.
For example: by another shell-script which works of predefined schedule (by crontab) and do two simple things:
  1. catalogs rman-backup of archivelogs of  the main db, in nocatalog-mode, in controlfile of the test db
  2. does `recover database delete archivelog` after the cataloging;

So in this state you have, at test-site, binary copy of your main-db, which is constantly recovered.
Conditionally, and to be short, let's call the mount-state db as "standby-db".
Please pay attention: it is not standby database in means which is used in official oracle-documentation;
It's just like it, in the sense of its purpose.
And nowhere is it written that you cannot and|or shouldn't obtain such "standby-db"
So, from here and ahead I'll use double-quotes for designate that it isn't an oracle-way standby-db
So, from this state you can move on, to the next very simple action: 
1. you're able to stop process of recovering of the "standby-db"
2. you're able to make zfs-snapshot of filesytem, in where all file-schema of the "standby-db" are placed;
3. you're able to make zfs-clone of the zfs-snapshot.
Аnd, at this stage, in form of the zfs-clone, you are getting physically separate, read-write filesystem **which provide you with the same data, and in the same state, as zfs-filesystem where, originally, file-schema of the "standby-db" is placed on**
4. From here and ahead it's just purely technical actions which your have to complete to startup new oracle-instance and tie it with the datafiles in the newly created zfs-clone filesystem, and fully open it;
5. you're able to start process of recovering of the "standby-db";
As soon as it works with datafiles in their own zfs-filesystem: it'll be recovered ahead and this processing will not interfere with datafiles in newly created zfs-clone;

So, in a few minutes and tiny price of disk-space you make clone-db: fully open, read-write db, from you "standby-db"
Оf corse, in means of table-data state the clone-db will be high actual to the main db;
And of couse, if you have enough memory (RAM) you're able to make more such clones.
If you add to the zfs-clone ability to make zfs-snapshot(s) for zfs-clone - it'll provide you with ability to "flashback" your clone db back to the previous state.

So let's turn back to the bash-script, which was announced at the start of the esse.
As a matter of fact the script does actions in points 1-5 in the last numeris list, plus "flashback" of the clone-db;

### Couple words about the bash script itself
Technically it's a file [script.sh](script.sh);
You place it somehere at test-site, for examle as `/opt/rias/sbin`, or another folder you like;
Script is supposed to be run under root, so:
```shell
[root@dev1 ~]# ls -lth /opt/rias/sbin/script.sh
-rwxrw-r-- 1 root root 49K Mar  3 23:33 /opt/rias/sbin/script.sh
```

I'll try to comment first several lines of the bash-script:
```shell
#!/bin/bash
#-- Init -----------------------------------------------------
. /etc/profile.d/ora_env.sh
. /etc/rias/dba/rman.conf
. /etc/rias/dba/script.conf
```
1. `ora_env.sh` in my case this is shell script which exports right oracle-env;
I mean: `ORACLE_HOME`,`ORACLE_SID`,`TNS_ADMIN`; It works with data from `/etc/oratab`
Actually you don't have to have this file. 
But it seems to me much more robust and right way to use it, istead of hardcoding the export-statements for exporting oracle-env related shell-variable in everywhere in scripts;
2. `/etc/rias/dba/rman.conf`
I mentioned before about some seprated script-based solution, which should be at this test-machine and should perfom recover operation anainst "standby-db"
In my case: this configuration file is a part of this solution;
It allows/disallows work of script which does recover of the "standby-db" and sets name of the log:
```shell
[root@dev1 ~]# cat /etc/rias/dba/rman.conf
LOG_FILE=/var/log/rias/dba/rman.log
RMAN_ENABLE=1
```
3. `/etc/rias/dba/script.conf` - some configuration related to the script [script.conf](script.conf)
I hope it's clear enough, from comments and code of the `script.sh` what does mean some key-value pair from the file;

### How to start it all in the work
Well, suppose that all preparations were completed;
That is: you prepared OS, at the test-machine;
Then you prepared zfs-pool and zfs-filesystems in it;
Then you prepared "standby-db" with entire it's file-schema placed in one of the zfs-filesystem. And setted name of the zfs-filesystem in `STANDBY_ZFS` in `script.conf`
Then you launch in work some script-solution which does recover og the "standby"
And then you check: if there enough memory for launch one another oracle-instance (for clone-db) at the test machine;

In that case you have to choose name, for the new clone-db; 
Suppose it is: `testdb0`
And prepare init-file for the clone-db: `$ORACLE_HOME/dbs/inittestdb0.ora`
In this init-file you have to set: `db_name='testdb0'`
And you have to set correctly name of the control file, in parameter `control_files`
Base name of the controlfile, of course, will be the same as the name of controlfile of the "standby-db";
But rest of full file path, after manipulation with zfs-filesystem will be different;

Next you should prepare sql-script, which should be executed against the test db after it will be created;
An example of such file is shown as script [prepare_instance.sql](prepare_instance.sql) 
You should write full name of the sql-script in `POST_OPERATION_SQL` key at `script.conf`

After it you're able to try to (re)create you test-db from your "standby-db" by executing:
```shell
sudo -u root -i
script.sh -r -n "testdb0"
```
After all you should see in your log-file something like [that](script.log), up to paths, database names, versions and etc.

Best regards and good luck
