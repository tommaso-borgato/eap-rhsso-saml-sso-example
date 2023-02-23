```shell
export NAMESPACE=test2

cat <<EOF > /tmp/OperatorGroup.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  annotations:
  name: $NAMESPACE-operators
  namespace: $NAMESPACE
spec:
  targetNamespaces:
    - $NAMESPACE
  upgradeStrategy: Default
EOF
oc apply -f /tmp/OperatorGroup.yaml


cat <<EOF > /tmp/Subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhsso-operator
spec:
  channel: stable
  config:
    env:
      - name: RELATED_IMAGE_RHSSO
        value: registry.redhat.io/rh-sso-7/sso76-openshift-rhel8:latest
      - name: PROFILE
        value: RHSSO
  name: rhsso-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
oc apply -f /tmp/Subscription.yaml


cat <<EOF > /tmp/Keycloak.yaml
apiVersion: keycloak.org/v1alpha1
kind: Keycloak
metadata:
  labels:
    app: sso
  name: rhsso-basic
spec:
  externalAccess:
    enabled: true
  instances: 1
EOF
oc apply -f /tmp/Keycloak.yaml
oc get secrets/credential-rhsso-basic -o jsonpath='{.data.ADMIN_USERNAME}' -n $NAMESPACE | base64 --decode
oc get secrets/credential-rhsso-basic -o jsonpath='{.data.ADMIN_PASSWORD}' -n $NAMESPACE | base64 --decode


cat <<EOF > /tmp/KeycloakRealm.yaml
apiVersion: keycloak.org/v1alpha1
kind: KeycloakRealm
metadata:
  name: saml-basic-auth
  labels:
    app: sso
spec:
  instanceSelector:
    matchLabels:
      app: sso
  realm:
    enabled: true
    users:
      - username: admin
        credentials:
          - type: password
            value: password
        enabled: true
        realmRoles:
          - admin
          - user
      - username: user
        credentials:
          - type: password
            value: user
        enabled: true
        realmRoles:
          - user
      # user needed for automatic client registration: needs role "create-client" of the "realm-management" client
      # the corresponding EAP configuration is SSO_USERNAME=client, SSO_PASSWORD=creator, etc..
      - username: client
        credentials:
          - type: password
            value: creator
        enabled: true
        clientRoles:
          account:
            - "manage-account"
          realm-management:
            - "create-client"
            # FIRST ERROR: in https://access.redhat.com/articles/6980008: withouth these roles the client is not automatically created:
            - "manage-realm"
            - "manage-clients"
    displayName: saml-basic-auth
    realm: saml-basic-auth
    id: saml-basic-auth
EOF
oc apply -f /tmp/KeycloakRealm.yaml
```

Note: SSO_URL must be set to Keycloak route + "/auth"
Note: what SSO_SECRET is, should be explained (I skipped setting it)

Create a SAML client on RH-SSO and download the keystore.jks (then delete the client: it's only needed to generate the keystore)

For the SAML client, use the following values:

    Archive Format:             JKS
    Key Alias:                  saml-app
    Key Password:               password
    Realm Certificate Alias:    saml-basic-auth
    Store Password:             password

Create a secret with keystore.jks:

```shell
oc delete secret eap-app-secret 
oc create secret generic eap-app-secret --from-file=keystore.jks=/home/tborgato/Downloads/keystore.jks --type=opaque
```

Install HELM release:

```shell
cat <<EOF > /tmp/values.yaml
build:
  uri: "https://github.com/tommaso-borgato/eap-rhsso-saml-sso-example.git"
  ref: "saml-feature-pack"
  mode: s2i
  env:
    - name: "MAVEN_MIRROR_URL"
      value: "http://repository.eapqe.psi.redhat.com:8081/artifactory/all/"
    - name: "MAVEN_ARGS_APPEND"
      value: " -Denforcer.skip=true -Dversion.war.maven.plugin=3.3.2"
deploy:
  replicas: 1
  env:
    - name: SSO_URL
      value: https://keycloak-$NAMESPACE.apps.tborgato-vnah.eapqe.psi.redhat.com/auth
    - name: SSO_REALM
      value: "saml-basic-auth"
    - name: SSO_USERNAME
      value: "client"
    - name: SSO_PASSWORD
      value: "creator"
    - name: HOSTNAME_HTTPS
      value: my-release-$NAMESPACE.apps.tborgato-vnah.eapqe.psi.redhat.com
    # SECOND ERROR: this field contains the Key Alias for the private key inside the keystore defined in SSO_SAML_KEYSTORE (otherwise you get Caused by: java.lang.NullPointerException: signingKey cannot be null)
    - name: SSO_SAML_CERTIFICATE_NAME
      value: "saml-app"
    - name: SSO_SAML_KEYSTORE
      value: "keystore.jks"
    - name: SSO_SAML_KEYSTORE_PASSWORD
      value: "password"
    - name: SSO_SAML_KEYSTORE_DIR
      value: "/etc/eap-app-secret-volume"
    - name: SSO_SAML_LOGOUT_PAGE
      value: "/index.jsp"
    - name: SSO_DISABLE_SSL_CERTIFICATE_VALIDATION
      value: "true"
    - name: SSO_SECRET
      value: "fakesecret"
 #   - name: HTTPS_SECRET
 #     value: "saml-app"
 #   - name: HTTPS_KEYSTORE
 #     value: "keystore.jks"
 #   - name: HTTPS_NAME
 #     value: https://my-release-$NAMESPACE.apps.tborgato-vnah.eapqe.psi.redhat.com
 #   - name: HTTPS_PASSWORD
 #     value: "password"
 #   - name: HTTPS_KEY_PASSWORD
 #     value: "password"
 #   - name: HTTPS_KEYSTORE_DIR
 #     value: "/etc/eap-app-secret-volume"
  volumeMounts:
    - mountPath: "/etc/eap-app-secret-volume"
      name: "eap-app-secret-volume"
      readOnly: true
  volumes:
    - name: "eap-app-secret-volume"
      secret:
        secretName: "eap-app-secret"
EOF

helm uninstall my-release --namespace $NAMESPACE
helm repo add jboss-eap https://jbossas.github.io/eap-charts/
helm install my-release -f /tmp/values.yaml jboss-eap/eap8 --namespace $NAMESPACE
```


