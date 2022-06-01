#!/bin/bash
set -eo pipefail
shopt -s nullglob
set -o xtrace

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi
CFG=/etc/mysql/node.cnf

# skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
	case "$arg" in
		-'?' | --help | --print-defaults | -V | --version)
			wantHelp=1
			break
			;;
	esac
done

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	set +o xtrace
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(<"${!fileVar}")"
	elif [ "${3:-}" ] && [ -f "/etc/mysql/mysql-users-secret/$3" ]; then
		val="$(</etc/mysql/mysql-users-secret/$3)"
	fi
	export "$var"="$val"
	unset "$fileVar"
	set -o xtrace
}

# usage: process_init_file FILENAME MYSQLCOMMAND...
#    ie: process_init_file foo.sh mysql -uroot
# (process a single initializer file, based on its extension. we define this
# function here, so that initializer scripts (*.sh) can use the same logic,
# potentially recursively, or override the logic used in subsequent calls)
process_init_file() {
	local f="$1"
	shift
	local mysql=("$@")

	case "$f" in
		*.sh)
			echo "$0: running $f"
			. "$f"
			;;
		*.sql)
			echo "$0: running $f"
			"${mysql[@]}" <"$f"
			echo
			;;
		*.sql.gz)
			echo "$0: running $f"
			gunzip -c "$f" | "${mysql[@]}"
			echo
			;;
		*) echo "$0: ignoring $f" ;;
	esac
	echo
}

_check_config() {
	toRun=("$@" --verbose --help --wsrep-provider='none')
	if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
		cat >&2 <<-EOM

			ERROR: mysqld failed while attempting to check config
			command was: "${toRun[*]}"

			$errors
		EOM
		exit 1
	fi
}

# Fetch value from server config
# We use mysqld --verbose --help instead of my_print_defaults because the
# latter only show values present in config files, and not server defaults
_get_config() {
	local conf="$1"
	shift
	"$@" --verbose --help --wsrep-provider='none' --log-bin-index="$(mktemp -u)" 2>/dev/null \
		| awk '$1 == "'"$conf"'" && /^[^ \t]/ { sub(/^[^ \t]+[ \t]+/, ""); print; exit }'
	# match "datadir      /some/path with/spaces in/it here" but not "--xyz=abc\n     datadir (xyz)"
}

# Fetch value from customized configs, needed for non-mysqld options like sst
_get_cnf_config() {
	local group=$1
	local var=${2//_/-}
	local reval=""

	reval=$(
		my_print_defaults "${group}" \
			| awk -F= '{st=index($0,"="); cur=$0; if ($1 ~ /_/) { gsub(/_/,"-",$1);} if (st != 0) { print $1"="substr(cur,st+1) } else { print cur }}' \
			| grep -- "--$var=" \
			| cut -d= -f2- \
			| tail -1
	)

	if [[ -z $reval ]]; then
		reval=$3
	fi
	echo "$reval"
}

# _get_tmpdir return temporary dir similar to 'initialize_tmpdir' function
# and $JOINER_SST_DIR selection logic inside 'wsrep_sst_xtrabackup-v2.sh'
_get_tmpdir() {
	local defaul_value="$1"
	local tmpdir_path=""

	tmpdir_path=$(_get_cnf_config sst tmpdir "")
	if [[ -z ${tmpdir_path} ]]; then
		tmpdir_path=$(_get_cnf_config xtrabackup tmpdir "")
	fi
	if [[ -z ${tmpdir_path} ]]; then
		tmpdir_path=$(_get_cnf_config mysqld tmpdir "")
	fi
	if [[ -z ${tmpdir_path} ]]; then
		tmpdir_path="$defaul_value"
	fi
	echo "$tmpdir_path"
}

function join {
	local IFS="$1"
	shift
	joined=$(tr "$IFS" '\n' <<<"$*" | sort -u | tr '\n' "$IFS")
	echo "${joined%?}"
}

MYSQL_VERSION=$(mysqld -V | awk '{print $3}' | awk -F'.' '{print $1"."$2}')
MYSQL_PATCH_VERSION=$(mysqld -V | awk '{print $3}' | awk -F'.' '{print $3}' | awk -F'-' '{print $1}')

# if vault secret file exists we assume we need to turn on encryption
vault_secret="/etc/mysql/vault-keyring-secret/keyring_vault.conf"
if [ -f "$vault_secret" ]; then
	sed -i "/\[mysqld\]/a early-plugin-load=keyring_vault.so" $CFG
	sed -i "/\[mysqld\]/a keyring_vault_config=$vault_secret" $CFG

	if [ "$MYSQL_VERSION" == '8.0' ]; then
		sed -i "/\[mysqld\]/a default_table_encryption=ON" $CFG
		sed -i "/\[mysqld\]/a table_encryption_privilege_check=ON" $CFG
		sed -i "/\[mysqld\]/a innodb_undo_log_encrypt=ON" $CFG
		sed -i "/\[mysqld\]/a innodb_redo_log_encrypt=ON" $CFG
		sed -i "/\[mysqld\]/a binlog_encryption=ON" $CFG
		sed -i "/\[mysqld\]/a binlog_rotate_encryption_master_key_at_startup=ON" $CFG
		sed -i "/\[mysqld\]/a innodb_temp_tablespace_encrypt=ON" $CFG
		sed -i "/\[mysqld\]/a innodb_parallel_dblwr_encrypt=ON" $CFG
		sed -i "/\[mysqld\]/a innodb_encrypt_online_alter_logs=ON" $CFG
		sed -i "/\[mysqld\]/a encrypt_tmp_files=ON" $CFG
	fi
fi

if [ -f "/usr/lib64/mysql/plugin/binlog_utils_udf.so" ]; then
  grep -E -q "^[#]?plugin_load" "$CFG" || sed '/^\[mysqld\]/a plugin_load="binlog_utils_udf=binlog_utils_udf.so"' ${CFG} 1<>${CFG}
  grep -E -q "^[#]?gtid-mode" "$CFG" || sed '/^\[mysqld\]/a gtid-mode=ON' ${CFG} 1<>${CFG}
  grep -E -q "^[#]?enforce-gtid-consistency" "$CFG" || sed '/^\[mysqld\]/a enforce-gtid-consistency' ${CFG} 1<>${CFG}

fi

# add sst.cpat to exclude pxc-entrypoint, unsafe-bootstrap, pxc-configure-pxc from SST cleanup
grep -q "^progress=" $CFG && sed -i "s|^progress=.*|progress=1|" $CFG
grep -q "^\[sst\]" "$CFG" || printf '[sst]\n' >>"$CFG"
grep -q "^cpat=" "$CFG" || sed '/^\[sst\]/a cpat=.*\\.pem$\\|.*init\\.ok$\\|.*galera\\.cache$\\|.*wsrep_recovery_verbose\\.log$\\|.*readiness-check\\.sh$\\|.*liveness-check\\.sh$\\|.*get-pxc-state$\\|.*sst_in_progress$\\|.*sst-xb-tmpdir$\\|.*\\.sst$\\|.*gvwstate\\.dat$\\|.*grastate\\.dat$\\|.*\\.err$\\|.*\\.log$\\|.*RPM_UPGRADE_MARKER$\\|.*RPM_UPGRADE_HISTORY$\\|.*pxc-entrypoint\\.sh$\\|.*unsafe-bootstrap\\.sh$\\|.*pxc-configure-pxc\\.sh\\|.*peer-list$' "$CFG" 1<>"$CFG"
if [[ $MYSQL_VERSION == '8.0' ]]; then
	if [[ $MYSQL_PATCH_VERSION -ge 26 ]]; then
		grep -q "^skip_replica_start=ON" "$CFG" || sed -i "/\[mysqld\]/a skip_replica_start=ON" $CFG
	else
		grep -q "^skip_slave_start=ON" "$CFG" || sed -i "/\[mysqld\]/a skip_slave_start=ON" $CFG
	fi
fi

file_env 'XTRABACKUP_PASSWORD' 'xtrabackup' 'xtrabackup'
file_env 'CLUSTERCHECK_PASSWORD' '' 'clustercheck'


# configure node.cnf for galera cluster

NODE_IP=$(hostname -I | awk ' { print $1 } ')
WSREP_CLUSTER_ADDRESS=$(cat "/scripts/peer-list")
NODE_NAME=$(hostname -f)
NODE_PORT=3306

CFG=/etc/mysql/node.cnf
MYSQL_VERSION=$(mysqld -V | awk '{print $3}' | awk -F'.' '{print $1"."$2}')
if [ "$MYSQL_VERSION" == '8.0' ]; then
	grep -E -q "^[#]?admin-address" "$CFG" || sed '/^\[mysqld\]/a admin-address=\n' ${CFG} 1<>${CFG}
	grep -E -q "^[#]?log_error_suppression_list" "$CFG" || sed '/^\[mysqld\]/a log_error_suppression_list="MY-010055"\n' ${CFG} 1<>${CFG}
else
	grep -E -q "^[#]?extra_max_connections" "$CFG" || sed '/^\[mysqld\]/a extra_max_connections=\n' ${CFG} 1<>${CFG}
	grep -E -q "^[#]?extra_port" "$CFG" || sed '/^\[mysqld\]/a extra_port=\n' ${CFG} 1<>${CFG}
fi

if [ "$IS_LOGCOLLECTOR" == 'yes' ]; then
	grep -E -q "^[#]?log-error" "$CFG" || sed "/^\[mysqld\]/a log-error=$LOG_DATA_DIR/mysqld-error.log\n" ${CFG} 1<>${CFG}
fi
#grep -E -q "^[#]?wsrep_sst_donor" "$CFG" || sed '/^\[mysqld\]/a wsrep_sst_donor=\n' ${CFG} 1<>${CFG}
grep -E -q "^[#]?wsrep_node_incoming_address" "$CFG" || sed '/^\[mysqld\]/a wsrep_node_incoming_address=\n' ${CFG} 1<>${CFG}
grep -E -q "^[#]?wsrep_provider_options" "$CFG" || sed '/^\[mysqld\]/a wsrep_provider_options="pc.weight=10"\n' ${CFG} 1<>${CFG}
#sed -r "s|^[#]?server_id=.*$|server_id=${SERVER_ID}|" ${CFG} 1<>${CFG}
sed -r "s|^[#]?coredumper$|coredumper|" ${CFG} 1<>${CFG}
sed -r "s|^[#]?wsrep_node_address=.*$|wsrep_node_address=${NODE_IP}|" ${CFG} 1<>${CFG}
sed -r "s|^[#]?wsrep_cluster_name=.*$|wsrep_cluster_name=${CLUSTER_NAME}|" ${CFG} 1<>${CFG}
#sed -r "s|^[#]?wsrep_sst_donor=.*$|wsrep_sst_donor=${DONOR_ADDRESS}|" ${CFG} 1<>${CFG}
sed -r "s|^[#]?wsrep_cluster_address=.*$|wsrep_cluster_address=gcomm://${WSREP_CLUSTER_ADDRESS}|" ${CFG} 1<>${CFG}
sed -r "s|^[#]?wsrep_node_incoming_address=.*$|wsrep_node_incoming_address=${NODE_NAME}:${NODE_PORT}|" ${CFG} 1<>${CFG}
{ set +x; } 2>/dev/null
ESCAPED_XTRABACKUP_PASSWORD=$(printf '%s\n' "$XTRABACKUP_PASSWORD" | sed -e 's/[]\|\&\!$*.^[]/\\&/g')
sed -r "s|^[#]?wsrep_sst_auth=.*$|wsrep_sst_auth='xtrabackup:$ESCAPED_XTRABACKUP_PASSWORD'|" ${CFG} 1<>${CFG}
set -x
sed -r "s|^[#]?admin-address=.*$|admin-address=${NODE_IP}|" ${CFG} 1<>${CFG}
sed -r "s|^[#]?extra_max_connections=.*$|extra_max_connections=100|" ${CFG} 1<>${CFG}
sed -r "s|^[#]?extra_port=.*$|extra_port=33062|" ${CFG} 1<>${CFG}


# https://www.percona.com/doc/percona-xtradb-cluster/LATEST/security/encrypt-traffic.html#ssl-manual-configuration
grep -E -q "^[#]?pxc_encrypt_cluster_traffic" "$CFG" || sed '/^\[mysqld\]/a pxc_encrypt_cluster_traffic=OFF' ${CFG} 1<>${CFG}

if [ ! -z $SSL_ENABLED ]; then
  grep -E -q "^[#]?encrypt" "$CFG" || sed '/^\[sst\]/a encrypt=4' ${CFG} 1<>${CFG}
  grep -E -q "^[#]?ssl-ca" "$CFG" || sed '/^\[sst\]/a ssl-ca=/etc/mysql/certs/server/ca.crt' ${CFG} 1<>${CFG}
  grep -E -q "^[#]?ssl-cert" "$CFG" || sed '/^\[sst\]/a ssl-cert=/etc/mysql/certs/server/tls.crt' ${CFG} 1<>${CFG}
  grep -E -q "^[#]?ssl-key" "$CFG" || sed '/^\[sst\]/a ssl-key=/etc/mysql/certs/server/tls.key' ${CFG} 1<>${CFG}
fi


if [ -z "$CLUSTER_JOIN" ] && [ "$1" = 'mysqld' -a -z "$wantHelp" ]; then
	# still need to check config, container may have started with --user
	_check_config "$@"

	# Get config
	DATADIR="$(_get_config 'datadir' "$@")"
	TMPDIR=$(_get_tmpdir "$DATADIR/sst-xb-tmpdir")

	rm -rfv "$TMPDIR"

	if [ ! -d "$DATADIR/mysql" ]; then
		file_env 'MYSQL_ROOT_PASSWORD' '' 'root'
		{ set +x; } 2>/dev/null
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and password option is not specified '
			echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
			exit 1
		fi
		set -x

		mkdir -p "$DATADIR"
		cpat="$(_get_cnf_config sst cpat)"
		find "$DATADIR" -mindepth 1 -regex "$cpat" -prune -o -exec rm -rfv {} \+ 1>/dev/null

		echo 'Initializing database'
		# we initialize database into $TMPDIR because "--initialize-insecure" option does not work if directory is not empty
		# in some cases storage driver creates unremovable artifacts (see K8SPXC-286), so $DATADIR cleanup is not possible
		"$@" --initialize-insecure --skip-ssl --datadir="$TMPDIR"
		mv "$TMPDIR"/* "$DATADIR/"
		rm -rfv "$TMPDIR"
		echo 'Database initialized'

		SOCKET="$(_get_config 'socket' "$@")"
		"$@" --skip-networking --socket="${SOCKET}" &
		pid="$!"

		mysql=(mysql --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" --password="")
		wsrep_local_state_select="SELECT variable_value FROM performance_schema.global_status WHERE variable_name='wsrep_local_state_comment'"

		for i in {120..0}; do
			wsrep_local_state=$(echo "$wsrep_local_state_select" | "${mysql[@]}" -s 2>/dev/null) || true
			if [ "$wsrep_local_state" = 'Synced' ]; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
			(
				echo "set wsrep_on=0;"
				echo "SET @@SESSION.SQL_LOG_BIN = off;"
				# sed is for https://bugs.mysql.com/bug.php?id=20545
				mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/'
				echo "set wsrep_on=1;"
			) | "${mysql[@]}" mysql
		fi

		{ set +x; } 2>/dev/null
		if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			MYSQL_ROOT_PASSWORD="$(pwmake 128)"
			echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
		fi
		set -x

		rootCreate=
		# default root to listen for connections from anywhere
		file_env 'MYSQL_ROOT_HOST' '%'
		if [ ! -z "$MYSQL_ROOT_HOST" -a "$MYSQL_ROOT_HOST" != 'localhost' ]; then
			# no, we don't care if read finds a terminating character in this heredoc
			# https://unix.stackexchange.com/questions/265149/why-is-set-o-errexit-breaking-this-read-heredoc-expression/265151#265151
			read -r -d '' rootCreate <<-EOSQL || true
				CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
				GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION ;
			EOSQL
		fi

		file_env 'MONITOR_HOST' 'localhost'
		file_env 'MONITOR_PASSWORD' 'monitor' 'monitor'
		file_env 'REPLICATION_PASSWORD' 'replication' 'replication'
		if [ "$MYSQL_VERSION" == '8.0' ]; then
			read -r -d '' monitorConnectGrant <<-EOSQL || true
				GRANT SERVICE_CONNECTION_ADMIN ON *.* TO 'monitor'@'${MONITOR_HOST}';
			EOSQL
		fi

		# SYSTEM_USER since 8.0.16
		# https://dev.mysql.com/doc/refman/8.0/en/privileges-provided.html#priv_system-user
		if [[ $MYSQL_VERSION == "8.0" ]] && ((MYSQL_PATCH_VERSION >= 16)); then
			read -r -d '' systemUserGrant <<-EOSQL || true
				GRANT SYSTEM_USER ON *.* TO 'monitor'@'${MONITOR_HOST}';
				GRANT SYSTEM_USER ON *.* TO 'clustercheck'@'localhost';
			EOSQL
		fi

		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;

			DELETE FROM mysql.user WHERE user NOT IN ('mysql.sys', 'mysqlxsys', 'root', 'mysql.infoschema', 'mysql.pxc.internal.session', 'mysql.pxc.sst.role', 'mysql.session') OR host NOT IN ('localhost') ;
			ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION ;
			${rootCreate}
			/*!80016 REVOKE SYSTEM_USER ON *.* FROM root */;

			CREATE USER 'operator'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${OPERATOR_ADMIN_PASSWORD}' ;
			GRANT ALL ON *.* TO 'operator'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION ;

			CREATE USER 'xtrabackup'@'%' IDENTIFIED BY '${XTRABACKUP_PASSWORD}';
			GRANT ALL ON *.* TO 'xtrabackup'@'%';

			CREATE USER 'monitor'@'${MONITOR_HOST}' IDENTIFIED BY '${MONITOR_PASSWORD}' WITH MAX_USER_CONNECTIONS 100;
			GRANT SELECT, PROCESS, SUPER, REPLICATION CLIENT, RELOAD ON *.* TO 'monitor'@'${MONITOR_HOST}';
			GRANT SELECT ON performance_schema.* TO 'monitor'@'${MONITOR_HOST}';
			${monitorConnectGrant}

			CREATE USER 'clustercheck'@'localhost' IDENTIFIED BY '${CLUSTERCHECK_PASSWORD}';
			GRANT PROCESS ON *.* TO 'clustercheck'@'localhost';

			${systemUserGrant}

			CREATE USER 'replication'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
			GRANT REPLICATION SLAVE ON *.* to 'replication'@'%';
			DROP DATABASE IF EXISTS test;
			FLUSH PRIVILEGES ;
		EOSQL

		{ set +x; } 2>/dev/null
		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			mysql+=(-p"${MYSQL_ROOT_PASSWORD}")
		fi
		set -x

		file_env 'MYSQL_DATABASE'
		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
			mysql+=("$MYSQL_DATABASE")
		fi

		file_env 'MYSQL_USER'
		file_env 'MYSQL_PASSWORD'
		{ set +x; } 2>/dev/null
		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
			fi

			echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
		fi
		set -x

		echo
		ls /docker-entrypoint-initdb.d/ >/dev/null
		for f in /docker-entrypoint-initdb.d/*; do
			process_init_file "$f" "${mysql[@]}"
		done

		{ set +x; } 2>/dev/null
		if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
			"${mysql[@]}" <<-EOSQL
				ALTER USER 'root'@'%' PASSWORD EXPIRE;
			EOSQL
		fi
		set -x
		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		echo
		echo 'MySQL init process done. Ready for start up.'
		echo
	fi

	# exit when MYSQL_INIT_ONLY environment variable is set to avoid starting mysqld
	if [ ! -z "$MYSQL_INIT_ONLY" ]; then
		echo 'Initialization complete, now exiting!'
		exit 0
	fi
fi

if [ "$1" = 'mysqld' -a -z "$wantHelp" ]; then
	# still need to check config, container may have started with --user
	_check_config "$@"

	DATADIR=$(_get_config 'datadir' "$@")
	SST_DIR=$(_get_cnf_config sst tmpdir "${DATADIR}/sst-xb-tmpdir")
	SST_P_FILE=$(_get_cnf_config sst progress "${DATADIR}/sst_in_progress")
	rm -rvf "${SST_DIR}" "${SST_P_FILE}"

	"$@" --version | sed 's/-ps//' | tee /tmp/version_info
	if [ -f "$DATADIR/version_info" ] && ! diff /tmp/version_info "$DATADIR/version_info"; then
		SOCKET="$(_get_config 'socket' "$@")"
		"$@" --skip-networking --socket="${SOCKET}" --wsrep-provider='none' &
		pid="$!"

		mysql=(mysql --protocol=socket -uoperator -hlocalhost --socket="${SOCKET}" --password="")
		{ set +x; } 2>/dev/null
		if [ ! -z "$OPERATOR_ADMIN_PASSWORD" ]; then
			mysql+=(-p"${OPERATOR_ADMIN_PASSWORD}")
		fi
		set -x

		for i in {120..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &>/dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		mysql_upgrade --force "${mysql[@]:1}"
		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi
	fi
	"$@" --version | sed 's/-ps//' >"$DATADIR/version_info"
	grep -v wsrep_sst_auth "$CFG"
fi

# run the mysqld
exec "$@"
