# CA
openssl req -new -newkey rsa:4096 -x509 -keyout ca-key.pem -out ca-certificate.pem -days 365 -passout pass:password -subj "/C=CZ/ST=CZ/L=Brno/O=QE/CN=xtf.ca"

keytool -import -noprompt -keystore truststore -file ca-certificate.pem -alias xtf.ca -storepass password

echo "Q" | openssl s_client -connect console-openshift-console.apps.tborgato-vnah.eapqe.psi.redhat.com:443 -showcerts 2>/dev/null > serversOpenSslResponse
echo "Q" | openssl s_client -connect keycloak-eap7--1999.apps.tborgato-vnah.eapqe.psi.redhat.com:443 -showcerts 2>/dev/null >> serversOpenSslResponse


csplit -f serverCert -s serversOpenSslResponse '/^-----BEGIN CERTIFICATE-----$/' '{*}'

find . -type f -not -name "serverCert00" -name "serverCert[0-9][0-9]" -exec openssl x509 -in {} -out {}.pem \;
find . -type f -name "serverCert[0-9][0-9].pem" -exec keytool -import -noprompt -keystore truststore -file {} -alias {} -storepass password \;


# keystore & truststore
export HOSTNAME=my-release-eap7--1999.apps.tborgato-vnah.eapqe.psi.redhat.com

keytool -genkeypair -keyalg RSA -noprompt -alias keyAlias -dname "CN=$HOSTNAME, OU=TF, O=XTF, L=Brno, S=CZ, C=CZ" -keystore keystore -storepass password -keypass password -deststoretype pkcs12

keytool -keystore keystore -certreq -alias keyAlias --keyalg rsa -file $HOSTNAME.csr -storepass password

openssl x509 -req -CA ca-certificate.pem -CAkey ca-key.pem -in $HOSTNAME.csr -out $HOSTNAME.cer -days 365 -CAcreateserial -passin pass:password

keytool -import -noprompt -keystore keystore -file ca-certificate.pem -alias xtf.ca -storepass password

keytool -import -keystore keystore -file $HOSTNAME.cer -alias keyAlias -storepass password


# secret
oc delete secret sso-saml-secret
oc create secret generic sso-saml-secret --from-file=keystore=keystore --from-file=truststore=truststore --type=opaque
oc create secret generic sso-saml-secret --from-file=keystore=/home/tborgato/Downloads/keystore.jks --type=opaque


helm repo add jboss-eap https://jbossas.github.io/eap-charts/
helm install my-release -f values.yaml jboss-eap/eap8 --namespace eap7--1999

helm uninstall my-release --namespace eap7--1999



# alternative 
openssl req -newkey rsa:2048 -new -nodes -x509 -days 3650 -keyout my-key.pem -out my-cert.pem -passout pass:password -subj "/C=CZ/ST=CZ/L=Brno/O=QE/CN=xtf.ca"

openssl pkcs12 -export -in my-cert.pem -inkey my-key.pem -name keycloak-eap7--1999.apps.tborgato-vnah.eapqe.psi.redhat.com -out keystore.p12 -password pass:password
keytool -importkeystore -deststorepass password -destkeystore keystore.jks -srckeystore keystore.p12 -srcstoretype PKCS12 -srcstorepass password

oc create secret generic sso-saml-secret --from-file=keystore=keystore.jks --type=opaque

#keytool -import -alias bundle -trustcacerts -file [ca_bundle] -keystore keystore.jks
#keytool -import -alias my-cert -trustcacerts -file my-cert.pem -keystore keystore.jks -deststorepass password


# alternative
oc rsync keycloak-0:/opt/eap/keystores/ . -c keycloak
oc create secret generic sso-saml-secret --from-file=keystore=https-keystore.jks --from-file=truststore=truststore.jks --type=opaque

# alternative
... create client in RH-SSO
oc delete secret sso-saml-secret -n eap7--1999
oc create secret generic sso-saml-secret --from-file=keystore=/home/tborgato/Downloads/keystore.jks --type=opaque -n eap7--1999
helm uninstall my-release --namespace eap7--1999
helm install my-release -f /home/tborgato/projects/APPSINT-DEMO/eap-rhsso-saml-sso-example/values.yaml jboss-eap/eap8 --namespace eap7--1999


# debug
oc debug deployment/my-release --as-root -n eap7--1999
vi /opt/eap/bin/launch/keycloak.sh
/opt/eap/bin/openshift-launch.sh

# alternative
openssl req -newkey rsa:2048 -new -nodes -x509 -days 3650 -keyout my-key.pem -out my-cert.pem -passout pass:password -subj "/C=CZ/ST=CZ/L=Brno/O=QE/CN=xtf.ca"
oc create secret tls sso-saml-secret --cert=my-cert.pem --key=my-key.pem -n eap7--1999
