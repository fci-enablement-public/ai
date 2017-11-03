FROM centos:7 
WORKDIR /
RUN yum -y install openldap-servers openldap-clients openssl vim
RUN chown -R ldap:ldap /var/lib/ldap

ENV SLAPD_URLS ldap:/// ldaps:/// ldapi:///
ENV SLAPD_OPTIONS ""
ENV MYPASS aml4u
ENV MYDOMAIN ibm

#RUN echo "olcRootPW: $(slappasswd -s $MYPASS)" >> /etc/openldap/slapd.d/cn=config/olcDatabase={2}hdb.ldif
#RUN sed -i "s/my-domain/$MYDOMAIN/g" /etc/openldap/slapd.d/cn\=config/olcDatabase\=\{2\}hdb.ldif

COPY setup-ai-openldap.sh /


#VOLUME ["/opt/project", "/data" ] 
#CMD ["/usr/libexec/openldap/check-config.sh"]
#CMD ["/usr/bin/sleep","3600"]
ENTRYPOINT ["/bin/bash", "-c"]
CMD ["/setup-ai-openldap.sh"]
#CMD ["sleep 3600"]
