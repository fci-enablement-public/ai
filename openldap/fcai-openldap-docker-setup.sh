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

# patch  fcai-docker-functions
fcai_funcs="$base/fcai-docker-functions"
if grep -q 'tag=.*cut -d:' $fcai_funcs ; then
  log.info "patching $fcai_funcs"
  sed -i -e 's/\(^.*tag=.*\)cut -d:\(.*$\)/\1cut -s -d:\2/g' $fcai_funcs
  sed -i '/# run the container/i\ repo=$(docker images | grep $repo | tr -s \" \" | cut -d \" \"  -f1)' $fcai_funcs 
  sed -i '/# run the container/i\ tag=$(docker images | grep $repo | tr -s \" \" | cut -d \" \"  -f2)' $fcai_funcs 
fi
source $fcai_funcs

# Deployment
log.div "Configuring openldap deployment"
rs_path="${base}/fcaiol-rs.yaml"

# delete previous deployment
log.info "deleting previous deployment"
fcai-docker delete -f $rs_path > /dev/null

log.info "configuring openldap container"
cat > "${rs_path}" <<-EOF
        apiVersion: apps/v1beta1 
        kind: ReplicaSet
        metadata: 
          name: fcaiol
        spec : 
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
                 name: fcaiol
             spec: 
               containers: 
               - name: openldap
                 image: fcienablementpublic/openldap
                 imagePullPolicy: Always
                 ports: 
                 - containerPort: 389
                   name: ldap
                 - containerPort: 636
                   name: ldaps
EOF

# validate file creation
[[ -f "${rs_path}" ]] && log.info "created "${rs_path}"" || log.error "could not create "${rs_path}""

# service
log.div "Configuring openldap service"
log.info "Creating openldap service"
svc_path="${base}/fcaiol-service.yaml"
cat > "${svc_path}" <<-EOL
	apiVersion: v1
	kind: Service
	metadata:
	  name: openldap
	spec:
	  ports:
	  - port: 389
	    name: ldap
	    targetPort: 389
	  - port: 636
	    name: ldaps 
	    targetPort: 636
	  selector:
	    name: fcaiol 
EOL

# validate file creation
[[ -f "${svc_path}" ]] && log.info "created "${svc_path}"" || log.error "could not create "${svc_path}""

# create the container
fcai-docker create -f $rs_path -s $svc_path --ipAddress 172.19.0.8

log.div "Update Config Map"
cm_path="${base}/fcai-configmap.yaml"

# validate path exists
[[ -f "${cm_path}" ]] || log.error ""${cm_path}" does not exist. This script will probably fail."
log.info "updating config map values for openldap"
sed -i '/GROUP_ANALYST/c\    AML_GROUP_ANALYST: "cn=analysts,dc=ibm,dc=com"' "${cm_path}"
sed -i '/GROUP_INVESTIGATOR/c\    AML_GROUP_INVESTIGATOR: "cn=investigators,dc=ibm,dc=com"' "${cm_path}"
sed -i '/GROUP_SUPERVISOR/c\    AML_GROUP_SUPERVISOR: "cn=supervisors,dc=ibm,dc=com"' "${cm_path}"
sed -i '/GROUP_ADMIN/c\    AML_GROUP_ADMIN: "cn=admins,dc=ibm,dc=com"' "${cm_path}"
sed -i '/E_ID/c\    AML_LDAP_PROFILE_ID: "uid"' "${cm_path}"
sed -i '/E_EMAIL/c\    AML_LDAP_PROFILE_EMAIL: "mail"' "${cm_path}"
sed -i '/E_DISPLAYNAME/c\    AML_LDAP_PROFILE_DISPLAYNAME: "displayName"' "${cm_path}"
sed -i '/E_GROUPS/c\    AML_LDAP_PROFILE_GROUPS: "memberOf"' "${cm_path}"
sed -i '/ER_URL/c\    AML_LDAP_SERVER_URL: "ldaps://172.19.0.8:636"' "${cm_path}"
sed -i '/R_BINDDN/c\    AML_LDAP_SERVER_BINDDN: "cn=Manager,dc=ibm,dc=com"' "${cm_path}"
sed -i '/DCREDENTIALS/c\    AML_LDAP_SERVER_BINDCREDENTIALS: "aml4u"' "${cm_path}"
sed -i '/ARCHBASE/c\    AML_LDAP_SERVER_SEARCHBASE: "dc=ibm,dc=com"' "${cm_path}"
sed -i '/E_MAPPING/c\    AML_LDAP_SERVER_USERNAME_MAPPING: "uid"' "${cm_path}"
sed -i '/ER_CERT/c\    AML_LDAP_SERVER_CERT: "ldap.crt"' "${cm_path}"

log.info "allowing self-signed certificates. do NOT do this in production!!! See nodejs GitHub issue 5258"
INSECURE='NODE_TLS_REJECT_UNAUTHORIZED: "0"'
grep -q -F "${INSECURE}" "${cm_path}" || echo "${INSECURE}" >> "${cm_path}"

fcai-docker create -f fcai-configmap.yaml --dbHost 172.19.0.2 --dbPort 56000 --esHost 172.19.0.4 --esPort 9200 --lsHost 172.19.0.5 --lsPort 5000 --redisHost 172.19.0.6 --redisPort 6379

log.div "Adding openldap's certificate to nodejs"
path="${base}/ldap.crt"
log.info "copying openldap cert to "${path}""
echo "docker exec -ti $(docker ps -f name=fcaiol) -- /usr/bin/cat /etc/openldap/certs/slapd-crt.pem > "${path}""
docker exec -ti $(docker ps -f name=fcaiol) -- /usr/bin/cat /etc/openldap/certs/slapd-crt.pem > "${path}"

# validate path exists
[[ -f "${path}" ]] || log.error ""${path}" does not exist. This script will probably fail."

log.info "re-creating the nodejs container"
fcai-docker delete -f fcainodejs-rs.yaml
fcai-docker create -f fcainodejs-rs.yaml  -s fcainodejs-service.yaml --ipAddress 172.19.0.7 -u 1000 --copy "$base/*.crt $base/*.pem"

log.div "Script completed"
echo
