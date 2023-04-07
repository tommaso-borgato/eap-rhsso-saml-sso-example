```bash
export NAMESPACE=keycloak-operator
```

```bash
oc create serviceaccount postgresql-serviceaccount
oc adm policy add-scc-to-user anyuid -z postgresql-serviceaccount

cat <<EOF > /tmp/Postgresql.yaml
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-db-secret
  namespace: $NAMESPACE
data:
  username: cG9zdGdyZXM= # postgres
  password: dGVzdHBhc3N3b3Jk # testpassword
type: Opaque
---
# PostgreSQL StatefulSet
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql-db
  namespace: $NAMESPACE
spec:
  serviceName: postgresql-db-service
  selector:
    matchLabels:
      app: postgresql-db
  replicas: 1
  template:
    metadata:
      labels:
        app: postgresql-db
    spec:
      serviceAccountName: postgresql-serviceaccount
      containers:
        - name: postgresql-db
          image: quay.io/tborgato/postgres
          env:
            - name: POSTGRES_PASSWORD
              value: testpassword
            - name: PGDATA
              value: /data/pgdata
            - name: POSTGRES_DB
              value: keycloak
---
# PostgreSQL StatefulSet Service
apiVersion: v1
kind: Service
metadata:
  name: postgres-db
  namespace: $NAMESPACE
spec:
  selector:
    app: postgresql-db
  type: LoadBalancer
  ports:
  - port: 5432
    targetPort: 5432
EOF
oc apply -f /tmp/Postgresql.yaml  
```


```bash
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
```

```bash
cat << EOF > /tmp/Subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: keycloak-operator
  namespace: $NAMESPACE
spec:
  channel: fast
  installPlanApproval: Automatic
  name: keycloak-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF
oc apply -f /tmp/Subscription.yaml
```

```bash
openssl req -newkey rsa:2048 -keyout key.pem -x509 -days 365 -out certificate.pem -nodes -subj '/CN=keycloak.example.com'

oc create secret tls keycloak-basic-tls-secret --cert=certificate.pem --key=key.pem --namespace $NAMESPACE
```

```bash
export OC_CONSOLE_HOSTNAME=$(oc get routes/console -n openshift-console --template='{{.spec.host}}')
export KEYCLOAK_HOSTNAME="keycloak-basic.${OC_CONSOLE_HOSTNAME#*\.}"

cat << EOF > /tmp/Keycloak.yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak-basic
  labels:
    app: sso
  namespace: $NAMESPACE
spec:
  hostname: 
    hostname: $KEYCLOAK_HOSTNAME
  ingress:
    enabled: true
  instances: 1
  http:
    tlsSecret: keycloak-basic-tls-secret
  db:
    vendor: postgres
    host: postgres-db
    usernameSecret:
      name: keycloak-db-secret
      key: username
    passwordSecret:
      name: keycloak-db-secret
      key: password    
EOF
oc apply -f /tmp/Keycloak.yaml
```

```bash
oc get secrets/keycloak-basic-initial-admin -o jsonpath='{.data.username}' -n $NAMESPACE | base64 --decode
oc get secrets/keycloak-basic-initial-admin -o jsonpath='{.data.password}' -n $NAMESPACE | base64 --decode
```

```bash
cat << EOF > /tmp/KeycloakRealmImport.yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: KeycloakRealmImport
metadata:
  name: saml-basic-auth
  labels:
    app: sso
  namespace: $NAMESPACE
spec:
  realm:
    realm: saml-basic-auth
    id: saml-basic-auth
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
            - "manage-realm"
            - "manage-clients"    
  keycloakCRName: keycloak-basic
EOF
oc apply -f /tmp/KeycloakRealmImport.yaml
```



```bash
KEYCLOAK_ROUTE=$(oc get ingress/keycloak-basic-ingress --template='{{ (index .spec.rules 0).host }}')
export SSO_URL=https://$KEYCLOAK_ROUTE

# if you don't use "Routes discovery"
KEYCLOAK_ROUTE=$(oc get ingress/keycloak-basic-ingress --template='{{ (index .spec.rules 0).host }}')
export HOSTNAME_HTTPS=${KEYCLOAK_ROUTE//basic-keycloak-/my-release-}

# if you use "Routes discovery": WildFly needs permissions to list routes
oc create role routeview --verb=list --resource=route -n $NAMESPACE
oc policy add-role-to-user routeview system:serviceaccount:$NAMESPACE:default --role-namespace=$NAMESPACE -n $NAMESPACE
```

```bash
cat <<EOF > /tmp/values.yaml
build:
  uri: "https://github.com/tommaso-borgato/eap-rhsso-saml-sso-example.git"
  ref: "saml-feature-pack-wf"
  mode: s2i
deploy:
  replicas: 1
  env:
    - name: SSO_URL
      value: $SSO_URL
    - name: SSO_REALM
      value: "saml-basic-auth"
    - name: SSO_USERNAME
      value: "client"
    - name: SSO_PASSWORD
      value: "creator"
    # decomment if you don't use "Routes discovery"
    #- name: HOSTNAME_HTTPS
    #  value: $HOSTNAME_HTTPS
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
  volumeMounts:
    - mountPath: "/etc/eap-app-secret-volume"
      name: "eap-app-secret-volume"
      readOnly: true
  volumes:
    - name: "eap-app-secret-volume"
      secret:
        secretName: "eap-app-secret"
EOF
```

```bash
helm repo add wildfly https://docs.wildfly.org/wildfly-charts/
helm install my-release -f /tmp/values.yaml wildfly/wildfly --namespace $NAMESPACE
```