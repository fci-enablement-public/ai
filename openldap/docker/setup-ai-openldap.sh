#!/bin/bash

cd /

echo "olcRootPW: $(slappasswd -s $MYPASS)" >> /etc/openldap/slapd.d/cn=config/olcDatabase={2}hdb.ldif
sed -i "s/my-domain/$MYDOMAIN/g" /etc/openldap/slapd.d/cn\=config/olcDatabase\=\{2\}hdb.ldif

# start slapd
#/usr/sbin/slapd -d 256 -u ldap -h "${SLAPD_URLS}" $SLAPD_OPTIONS
/usr/sbin/slapd -u ldap -h "${SLAPD_URLS}" $SLAPD_OPTIONS
sleep 5 

# probably unnecessary
ldapadd -H ldapi:/// -f /etc/openldap/schema/cosine.ldif
ldapadd -H ldapi:/// -f /etc/openldap/schema/inetorgperson.ldif

# create memberof.ldif
cat > memberof.ldif <<-EOF
	# Enable memberOf overlay

	dn: cn=module,cn=config
	cn: module
	objectClass: olcModuleList
	olcModuleLoad: memberof
	olcModulePath: /usr/lib64/openldap

	# Configure memberOf overlay

	dn: olcOverlay={0}memberof,olcDatabase={2}hdb,cn=config
	objectClass: olcConfig
	objectClass: olcMemberOf
	objectClass: olcOverlayConfig
	objectClass: top
	olcOverlay: memberof
EOF

# Load the LDIF file:
ldapadd -H ldapi:/// -f memberof.ldif

# Create tree.ldif
cat > tree.ldif <<-EOF
	dn: dc=ibm,dc=com
	objectClass: top
	objectClass: organization
	objectClass: dcObject
	o: ibm organization
	dc: ibm
EOF

# Load the LDIF file:
ldapadd -D "cn=Manager,dc=$MYDOMAIN,dc=com" -w $MYPASS -f tree.ldif

# create users
cat > users.ldif <<-EOF
	dn: uid=analyst1,dc=ibm,dc=com
	objectClass: top
	objectClass: inetOrgPerson
	uid: analyst1
	cn: analyst1
	sn: analyst1
	displayName: analyst1
	mail: analyst1@ibm.com
	userpassword: aml4u

	dn: uid=investigator1,dc=ibm,dc=com
	objectClass: top
	objectClass: inetOrgPerson
	uid: investigator1
	cn: investigator1
	sn: investigator1
	displayName: investigator1
	mail: investigator1@ibm.com
	userpassword: aml4u

	dn: uid=supervisor1,dc=ibm,dc=com
	objectClass: top
	objectClass: inetOrgPerson
	uid: supervisor1
	cn: supervisor1
	sn: supervisor1
	displayName: supervisor1
	mail: supervisor1@ibm.com
	userpassword: aml4u

	dn: uid=admin1,dc=ibm,dc=com
	objectClass: top
	objectClass: inetOrgPerson
	uid: admin1
	cn: admin1
	sn: admin1
	displayName: admin1
	mail: admin1@ibm.com
	userpassword: aml4u
EOF

# load the LDIF file
ldapadd -D "cn=Manager,dc=$MYDOMAIN,dc=com" -w $MYPASS -f users.ldif

# Test that analyst1 can bind
ldapsearch -LL -D "uid=analyst1,dc=$MYDOMAIN,dc=com" -w $MYPASS -b "dc=$MYDOMAIN,dc=com" "(uid=analyst1)"

# Configure aml-compatible groups
cat > groups.ldif <<-EOF
	dn: cn=analysts,dc=ibm,dc=com
	objectClass: top
	objectClass: groupOfNames
	cn: analysts
	member: uid=analyst1,dc=ibm,dc=com

	dn: cn=investigators,dc=ibm,dc=com
	objectClass: top
	objectClass: groupOfNames
	cn: users
	member: uid=investigator1,dc=ibm,dc=com

	dn: cn=supervisors,dc=ibm,dc=com
	objectClass: top
	objectClass: groupOfNames
	cn: users
	member: uid=supervisor1,dc=ibm,dc=com   

	dn: cn=admins,dc=ibm,dc=com
	objectClass: top
	objectClass: groupOfNames
	cn: users
	member: uid=admin1,dc=ibm,dc=com 
EOF

# Load the LDIF file
ldapadd -D "cn=Manager,dc=$MYDOMAIN,dc=com" -w $MYPASS -f groups.ldif

# Test memberOf 
ldapsearch -LL -H ldapi:// -b "dc=$MYDOMAIN,dc=com" "(&(memberof=*)(uid=*))" memberof

# Create keys
cd /etc/openldap/certs
openssl req -x509 -nodes -newkey rsa:4096 -keyout slapd-key.pem -subj "/C=US/ST=Texas/L=Austin/O=IBM/OU=Support/CN=$(hostname -f)" -reqexts SAN -extensions SAN -config <(cat /etc/pki/tls/openssl.cnf <(printf "\n[SAN]\nsubjectAltName=DNS:openldap")) -days 3650 -out slapd-crt.pem 
cd -

cat > tls.ldif <<-EOF
	dn: cn=config
	changetype:  modify
	replace: olcTLSCACertificateFile
	olcTLSCACertificateFile: /etc/openldap/certs/slapd-crt.pem
	-
	replace: olcTLSCACertificatePath
	olcTLSCACertificatePath: /etc/openldap/certs
	-
	replace: olcTLSCertificateFile
	olcTLSCertificateFile: /etc/openldap/certs/slapd-crt.pem
	-
	replace: olcTLSCertificateKeyFile
	olcTLSCertificateKeyFile: /etc/openldap/certs/slapd-key.pem
	-
	replace: olcTLSCipherSuite
	olcTLSCipherSuite: HIGH+TLSv1.2+AES256
EOF

# Load the LDIF file
ldapmodify -H ldapi:// -f tls.ldif

# Force TLS
cat > force-tls.ldif <<-EOF
	dn: olcDatabase={2}hdb,cn=config
	changetype:  modify
	replace: olcSecurity
	olcSecurity: tls=256
EOF

# Load the LDIF file
ldapmodify -H ldapi:// -f force-tls.ldif

# Restart slapd
pkill -f slapd
sleep 5
/usr/sbin/slapd -u ldap -h "${SLAPD_URLS}" $SLAPD_OPTIONS
sleep 5

# Trust openldap server
cat >> /etc/openldap/ldap.conf <<- EOF
	# Instruct the openldap client to trust these cert(s)
	TLS_CACERT   /etc/openldap/certs/slapd-crt.pem
EOF

# Verify Security
echo "the following command should fail:"
ldapsearch -D "cn=Manager,dc=$MYDOMAIN,dc=com" -w $MYPASS -b "cn=$MYDOMAIN,cn=com" -s sub "(uid=analyst1)"


echo "the following should work. It test STARTTLS (TLS over port 389)"
ldapsearch -LL -ZZ -H ldap://$(hostname -f) -D "cn=Manager,dc=$MYDOMAIN,dc=com" -w $MYPASS -b "dc=$MYDOMAIN,dc=com" "(uid=analyst1)"


echo "Test STARTTLS (TLS over port 389):"
ldapsearch -LL -ZZ -H ldap://$(hostname -f) -D "cn=Manager,dc=$MYDOMAIN,dc=com" -w $MYPASS -b "dc=$MYDOMAIN,dc=com" "(uid=analyst1)"

echo "additional tests"

echo "Test ldaps:// (TLS over port 636):"
ldapsearch -LL -H ldaps://$(hostname -f):636 -D "cn=Manager,dc=$MYDOMAIN,dc=com" -w $MYPASS -b "dc=$MYDOMAIN,dc=com" "(uid=analyst1)"

# Restart slapd
pkill -f slapd
sleep 5

# Run slapd in daemon (really debug level) mode to keep the container running
/usr/sbin/slapd -d 256 -u ldap -h "${SLAPD_URLS}" $SLAPD_OPTIONS
