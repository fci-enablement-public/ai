#!/bin/bash
#
# set up an OpenLDAP docker container for FCAI

# Constants
# Constants
RED=$'\e[31m'
BLUE=$'\e[34m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
NC=$'\e[0m'
PC=$GREEN # Prompt Color
DIVIDER="$(printf "%0.s-" {1..80})"

# Aliases are not expanded when the shell is not interactive, unless the expand_aliases shell option is set using shopt
shopt -s expand_aliases

# Handle interrupts (Ctrl+C)
exit_on_signal_SIGINT () { printf "\n${NC}Script interrupted.\n\n" 2>&1; exit 0; }
exit_on_signal_SIGTERM () { printf "\n${NC}Script terminated.\n\n" 2>&1; exit 0; }

# Create visual separator
separator() { printf "${NC}\n%s \n\t%s \n%s \n" "$DIVIDER" "$1" "$DIVIDER" ; }

# Set traps
trap exit_on_signal_SIGINT SIGINT
trap exit_on_signal_SIGTERM SIGTERM

# Set aliases
alias log.info='echo [INFO][line $LINENO] ${ITEM} - '
alias log.error='echo [ERROR][line $LINENO] ${ITEM} - '
alias log.warn='echo [WARNING][line $LINENO] ${ITEM} - '
alias log.div=separator

# Base
#base='/tmp/FCAI 1.0.1 APAR1/fcai-install/deploy'
base=$(dirname $0)
log.warn "Deployment directory is: ${base}"

# source fcai-docker-functions
fcai_funcs="$base/fcai-docker-functions"
source $fcai_funcs

# Deployment
log.div "Configuring openldap deployment"
rs_path="${base}/fcaiol-rs.yaml"

# delete previous deployment
log.info "deleting previous deployment"
fcai-docker delete -f $rs_path > /dev/null

log.info "configuring openldap container"
cat > "${rs_path}" <<EOF
apiVersion: apps/v1beta1
kind: ReplicaSet
metadata:
  name: fcai-openldap
spec:
  replicas: 1
  minReadySeconds: 10
  strategy :
     type: RollingUpdate
     rollingUpdate:
       maxUnavailable: 1
       maxSurge: 1
  template:
     metadata:
       labels:
         name: fcai-openldap
     spec:
       containers:
       - name: fcai-openldap
         image: fcienablementpublic/openldap:1.0.2
         imagePullPolicy: Always
         ports:
         - containerPort: 389
           name: ldap
           hostPort: 11389
         - containerPort: 636
           name: ldaps
           hostPort: 11636
EOF

# validate file creation
[[ -f "${rs_path}" ]] && log.info "created "${rs_path}"" || log.error "could not create "${rs_path}""

# service
log.div "Configuring openldap service"
log.info "Creating openldap service"
svc_path="${base}/fcai-openldap-service.yaml"
cat > "${svc_path}" <<-EOL
	apiVersion: v1
	kind: Service
	metadata:
	  name: fcai-openldap
	spec:
	  type: NodePort
	  ports:
	  - port: 389
	    name: ldap
	    nodePort: 30389
	  - port: 636
	    name: ldaps 
	    nodePort: 30636
	  selector:
	    name: fcai-openldap 
EOL

# validate file creation
[[ -f "${svc_path}" ]] && log.info "created "${svc_path}"" || log.error "could not create "${svc_path}""

# create the container
fcai-docker create -f $rs_path -s $svc_path --ipAddress 172.19.0.8

log.div "Update FCAI properties"
props_path="${base}/fcai.properties"
[[ -f "${props_path}" ]] || log.error ""${props_path}" does not exist. This script will probably fail."
log.info "updating FCAI properties for openldap"
sed -i '/aml.group.analyst/c\aml.group.analyst = cn=analysts,dc=ibm,dc=com' "${props_path}"
sed -i '/aml.group.investigator/c\aml.group.investigator = cn=investigators,dc=ibm,dc=com' "${props_path}"
sed -i '/aml.group.supervisor/c\aml.group.supervisor = cn=supervisors,dc=ibm,dc=com' "${props_path}"
sed -i '/aml.group.admin/c\aml.group.admin = cn=admins,dc=ibm,dc=com' "${props_path}"

sed -i '/aml.ldap.profile.id/c\aml.ldap.profile.id = uid' "${props_path}"
sed -i '/aml.ldap.profile.email/c\aml.ldap.profile.email = mail' "${props_path}"
sed -i '/aml.ldap.profile.displayname/c\aml.ldap.profile.displayname = displayName' "${props_path}"
sed -i '/aml.ldap.profile.groups/c\aml.ldap.profile.groups = memberOf' "${props_path}"

sed -i '/aml.ldap.server.url/c\aml.ldap.server.url = ldaps://fcai-openldap:636' "${props_path}"
sed -i '/aml.ldap.server.binddn/c\aml.ldap.server.binddn = cn=Manager,dc=ibm,dc=com' "${props_path}"
sed -i '/aml.ldap.server.bindcredentials/c\aml.ldap.server.bindcredentials = YW1sNHU=' "${props_path}"
sed -i '/aml.ldap.server.searchbase/c\aml.ldap.server.searchbase = dc=ibm,dc=com' "${props_path}"
sed -i '/aml.ldap.server.username.mapping/c\aml.ldap.server.username.mapping = uid' "${props_path}"
sed -i '/aml.ldap.server.cert/c\aml.ldap.server.cert = ldap.crt' "${props_path}"

$base/fcai-props-to-yaml.sh

log.div "Update Config Map"
cm_path="${base}/fcai-configmap.yaml"
[[ -f "${cm_path}" ]] || log.error ""${cm_path}" does not exist. This script will probably fail."
fcai-docker create -f fcai-configmap.yaml --dbHost 172.19.0.2 --dbPort 56000 --esHost 172.19.0.4 --esPort 9200 --lsHost 172.19.0.5 --lsPort 5000 --redisHost 172.19.0.6 --redisPort 6379

log.div "Adding openldap's certificate to nodejs"
# make time for the container to extract the slapd cert
sleep 10 
path="${base}/ldap.crt"
log.info "copying openldap cert to "${path}""
echo "docker cp $(docker ps -q -f name=fcai-openldap):/etc/openldap/certs/slapd-crt.pem $path"
docker cp $(docker ps -q -f name=fcai-openldap):/etc/openldap/certs/slapd-crt.pem $path
[[ -f "${path}" ]] || log.error ""${path}" does not exist. This script will probably fail."

log.info "re-creating the nodejs container"
fcai-docker delete -f fcainodejs-rs.yaml
fcai-docker create -f fcainodejs-rs.yaml  -s fcainodejs-service.yaml --ipAddress 172.19.0.7 -u 1000 --copy "$base/*.crt,$base/*.pem" --addHost fcai-openldap:172.19.0.8

log.div "Script completed"
echo
