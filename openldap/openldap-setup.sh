#!/bin/bash
#
# set up openldap in k8s cluster

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

# Deployment
log.div "Configuring openldap deployment"

# delete previous deployment
log.info "deleting previous deployment"
kubectl delete deploy fcaiol 2> /dev/null

log.info "creating deployment"
base='/tmp/FCAI 1.0.1 APAR1/fcai-install/deploy'
log.warn "NOTE: This script assumes that your deployment directory is: ${base}. If that's incorrect, change this script on the line shown to the left."
path="${base}/fcaiol-deploy.yaml"
cat > "${path}" <<-EOF
        apiVersion: apps/v1beta1 
        kind: Deployment 
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
[[ -f "${path}" ]] && log.info "created "${path}"" || log.error "could not create "${path}""

# create deployment
log.info "creating new deployment"
kubectl create -f "${path}"

log.info "naively waiting 10 seconds for openldap pod to start on the scheduled Node (it could take 60 seconds or longer in reality). If you can't log in to AML when this script finishes, please re-run this script."
sleep 10 

# service
log.div "Configuring openldap service"
# delete previous deployment
log.info "deleting any previous openldap service"
kubectl delete svc openldap 2> /dev/null

log.info "Creating openldap service"
path="${base}/fcaiol-svc.yaml"
cat > "${path}" <<-EOL
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
[[ -f "${path}" ]] && log.info "created "${path}"" || log.error "could not create "${path}""

log.info "creating service"
kubectl create -f "${path}"

log.div "Update Config Map"
path="${base}/fcai-configmap.yaml"

# validate path exists
[[ -f "${path}" ]] || log.error ""${path}" does not exist. This script will probably fail."

log.info "updating config map values for openldap"
sed -i '/GROUP_ANALYST/c\    AML_GROUP_ANALYST: "cn=analysts,dc=ibm,dc=com"' "${path}"
sed -i '/GROUP_INVESTIGATOR/c\    AML_GROUP_INVESTIGATOR: "cn=investigators,dc=ibm,dc=com"' "${path}"
sed -i '/GROUP_SUPERVISOR/c\    AML_GROUP_SUPERVISOR: "cn=supervisors,dc=ibm,dc=com"' "${path}"
sed -i '/GROUP_ADMIN/c\    AML_GROUP_ADMIN: "cn=admins,dc=ibm,dc=com"' "${path}"
sed -i '/E_ID/c\    AML_LDAP_PROFILE_ID: "uid"' "${path}"
sed -i '/E_EMAIL/c\    AML_LDAP_PROFILE_EMAIL: "mail"' "${path}"
sed -i '/E_DISPLAYNAME/c\    AML_LDAP_PROFILE_DISPLAYNAME: "displayName"' "${path}"
sed -i '/E_GROUPS/c\    AML_LDAP_PROFILE_GROUPS: "memberOf"' "${path}"
sed -i '/ER_URL/c\    AML_LDAP_SERVER_URL: "ldaps://openldap:636"' "${path}"
sed -i '/R_BINDDN/c\    AML_LDAP_SERVER_BINDDN: "cn=Manager,dc=ibm,dc=com"' "${path}"
sed -i '/DCREDENTIALS/c\    AML_LDAP_SERVER_BINDCREDENTIALS: "aml4u"' "${path}"
sed -i '/ARCHBASE/c\    AML_LDAP_SERVER_SEARCHBASE: "dc=ibm,dc=com"' "${path}"
sed -i '/E_MAPPING/c\    AML_LDAP_SERVER_USERNAME_MAPPING: "uid"' "${path}"
sed -i '/ER_CERT/c\    AML_LDAP_SERVER_CERT: "ldap.crt"' "${path}"

log.info "allowing self-signed certificates. do NOT do this in production!!! See nodejs GitHub issue 5258"
INSECURE='NODE_TLS_REJECT_UNAUTHORIZED: "0"'
grep -q -F "${INSECURE}" "${path}" || echo "${INSECURE}" >> "${path}"

log.info "deleting and recreating map"
kubectl delete cm fcai-config
kubectl create -f "${path}"
log.info "waiting 5 seconds for the config map to be recreated"
sleep 5 

log.div "Adding openldap's certificate to nodejs"
path="${base}/ldap.crt"
log.info "copying openldap pod's cert to "${path}""
echo "kubectl exec -ti $(kubectl get pods | grep fcaiol | awk '{print $1}') -- /usr/bin/cat /etc/openldap/certs/slapd-crt.pem > "${path}""
kubectl exec -ti $(kubectl get pods | grep fcaiol | awk '{print $1}') -- /usr/bin/cat /etc/openldap/certs/slapd-crt.pem > "${path}"

# validate path exists
[[ -f "${path}" ]] || log.error ""${path}" does not exist. This script will probably fail."

log.info "recreating kubernetes certs volume"
kubectl delete secret fcai-tls

log.info "moving into deploy folder"
path="${base}"
cd "${path}"
kubectl create secret generic fcai-tls --from-file=fcai.crt --from-file=fcai.pem --from-file=db2.crt --from-file=ldap.crt
log.info "deleting the nodejs pod, which will be automatically recreated"
kubectl delete pod $(kubectl get pods | grep fcainodejs | awk '{print $1}')
cd -

log.div "Script completed"
echo
