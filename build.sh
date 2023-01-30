#export SSO_URL="http://0.0.0.0:8081/realms/saml-test-realm/protocol/saml"
#export SSO_REALM="saml-test-realm"
#export SSO_USERNAME="admin"
#export SSO_PASSWORD="admin"
#export HOSTNAME_HTTP="http://localhost:8080"

mvn clean package -P EAP7-1999 && ./target/server/bin/standalone.sh