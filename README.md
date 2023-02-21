# CA
openssl req -new -newkey rsa:4096 -x509 -keyout ca-key.pem -out ca-certificate.pem -days 365 -passout pass:password -subj "/C=CZ/ST=CZ/L=Brno/O=QE/CN=xtf.ca"

keytool -import -noprompt -keystore truststore -file ca-certificate.pem -alias xtf.ca -storepass password



# keystore & truststore
keytool -genkeypair -keyalg RSA -noprompt -alias keyAlias -dname "CN=hostname, OU=TF, O=XTF, L=Brno, S=CZ, C=CZ" -keystore keystore -storepass password -keypass password -deststoretype pkcs12

keytool -keystore keystore -certreq -alias keyAlias --keyalg rsa -file hostname.csr -storepass password

openssl x509 -req -CA ca-certificate.pem -CAkey ca-key.pem -in hostname.csr -out hostname.cer -days 365 -CAcreateserial -passin pass:password

keytool -import -noprompt -keystore keystore -file ca-certificate.pem -alias xtf.ca -storepass password

keytool -import -keystore keystore -file hostname.cer -alias keyAlias -storepass password


# secret
oc create secret generic sso-saml-secret --from-file=keystore=keystore --from-file=truststore=truststore --type=opaque

helm repo add jboss-eap https://jbossas.github.io/eap-charts/
helm install my-release -f values.yaml jboss-eap/eap8 --namespace eap7--1999


helm uninstall my-release --namespace eap7--1999