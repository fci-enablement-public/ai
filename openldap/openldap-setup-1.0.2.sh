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
log.info "deleting any previous fcai-openldap deployment"
kubectl delete deploy fcai-openldap 2> /dev/null

log.info "creating deployment"
base="/fcai/fcai-install/deploy"
log.warn "NOTE: This script assumes that your deployment directory is: ${base}. If that's incorrect, change this script on the line shown to the left."
path="${base}/fcai-openldap-deploy.yaml"
cat > "${path}" <<EOF
apiVersion: apps/v1beta1
kind: Deployment
metadata:
  name: fcai-openldap
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
[[ -f "${path}" ]] && log.info "created "${path}"" || log.error "could not create "${path}""

# create deployment
log.info "creating new deployment"
kubectl create -f "${path}"
log.div "NOTE!"
log.info "Optimistically waiting 10 seconds for openldap pod to start on the scheduled Node (it could take 60 seconds or longer in reality). If you can't log in when this script finishes, please re-run this script."
sleep 10 

# service
log.div "Configuring openldap service"
# delete previous deployment
log.info "deleting any previous openldap service"
kubectl delete svc fcai-openldap 2> /dev/null

log.info "Creating openldap service"
path="${base}/fcai-openldap-svc.yaml"
cat > "${path}" <<-EOL
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
sed -i '/ER_URL/c\    AML_LDAP_SERVER_URL: "ldaps://fcai-openldap:636"' "${path}"
sed -i '/R_BINDDN/c\    AML_LDAP_SERVER_BINDDN: "cn=Manager,dc=ibm,dc=com"' "${path}"
sed -i '/AML_LDAP_SERVER_BINDCREDENTIALS/d' "${path}"
echo '    AML_LDAP_SERVER_BINDCREDENTIALS: "aml4u"' >> ${path}
sed -i '/ARCHBASE/c\    AML_LDAP_SERVER_SEARCHBASE: "dc=ibm,dc=com"' "${path}"
sed -i '/E_MAPPING/c\    AML_LDAP_SERVER_USERNAME_MAPPING: "uid"' "${path}"
sed -i '/ER_CERT/c\    AML_LDAP_SERVER_CERT: "ldap.crt"' "${path}"

log.info "allowing self-signed certificates. do NOT do this in production!!! See nodejs GitHub issue 5258"
INSECURE='    NODE_TLS_REJECT_UNAUTHORIZED: "0"'
grep -q -F "${INSECURE}" "${path}" || echo "${INSECURE}" >> "${path}"

log.info "deleting and recreating map"
kubectl delete cm fcai-config
kubectl create -f "${path}"
log.info "waiting 5 seconds for the config map to be recreated"
sleep 5 

log.div "Adding openldap's certificate to nodejs"
path="${base}/ldap.crt"
log.info "copying openldap pod's cert to "${path}""
echo "kubectl exec -ti $(kubectl get pods | grep fcai-openldap | awk '{print $1}') -- /usr/bin/cat /etc/openldap/certs/slapd-crt.pem > "${path}""
kubectl exec -ti $(kubectl get pods | grep fcai-openldap | awk '{print $1}') -- /usr/bin/cat /etc/openldap/certs/slapd-crt.pem > "${path}"

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
log.info "Verify the results above and try to login below. Re-run this script if you're seeing problems."

# Get the IP of the NIC used as default gateway
IP=$(ip route get 1 | awk '{print $NF;exit}')

log.div "Next Step"
printf "%-30s%-30s\n" "Open GUI URL" "https://$(hostname -f):30400"

log.div "Usernames and Passwords"
printf "%-30s%-30s\n" "admin1" "aml4u"
printf "%-30s%-30s\n" "investigator1" "aml4u"
printf "%-30s%-30s\n" "supervisor1" "aml4u"
printf "%-30s%-30s\n" "analyst1" "aml4u"

log.div "Troubleshooting"
printf "%-30s%-30s\n" "Inspect UI's logs" "kubectl logs \$(kubectl get pods | grep fcainodejs | awk '{print \$1}')"
printf "%-30s%-30s\n" "Correct script?" "If you have an APAR (e.g., apar1), be sure this script is specific to that APAR."

log.div "Optional: LDAP client"
printf "%-30s%-30s\n" "Configure LDAP client 1/5" "Point your LDAP client here: ldaps://fcai-openldap:30636"
printf "%-30s%-30s\n" "Configure LDAP client 2/5" "In LDAP client's /etc/hosts (or equivalent), add this entry (modify as needed): ${IP} fcai-openldap"
printf "%-30s%-30s\n" "Configure LDAP client 3/5" "Login/bind as: cn=Manager,dc=ibm,dc=com with password: aml4u"
printf "%-30s%-30s\n" "Configure LDAP client 4/5" "Run this command and add the resulting cert into your ldap client: cat ${base}/ldap.crt"
printf "%-30s%-30s\n" "Configure LDAP client 5/5" "Test a connection from the client: ldapsearch -d5 -x -H ldaps://fcai-openldap:30636 -D cn=Manager,dc=ibm,dc=com -w aml4u -b dc=ibm,dc=com -s sub 'objectclass=*' 2>&1| less"

echo
echo
