=== Using the `keycloak-saml` layer with WildFly

The `keycloak-saml` layer is intended to be used just with the `wildfly-maven-plugin` in `s2i` builds;
The `s2i` build with the `wildfly-maven-plugin`, represents the only workflow which supports `SSO_*` environment
variables listed in https://github.com/wildfly/wildfly-cekit-modules/blob/main/jboss/container/wildfly/launch/keycloak/2.0/module.yaml#L8[Keycloak Env Vars];

==== OpenShift namespace

Create a new OpenShift namespace and store its name in a shell variable:

```bash
export NAMESPACE=test-postgresql
oc new-project $NAMESPACE
```

==== keycloak setup

Deploy Keycloak using the Keycloak Operator (note we are using the productized version of Keycloak here):

Create an `OperatorGroup`:

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

Create a `Subscription` to the Keycloak Operator:

```bash
cat <<EOF > /tmp/Subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: keycloak-operator
spec:
  channel: fast
  installPlanApproval: Automatic
  name: keycloak-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
  startingCSV: keycloak-operator.v21.0.0
EOF

oc apply -f /tmp/Subscription.yaml
```

Deploy a `PostgreSQL` instance:

```bash
oc create serviceaccount postgresql-serviceaccount
oc adm policy add-scc-to-user anyuid -z postgresql-serviceaccount

cat <<EOF > /tmp/PostgreSQL.yaml
kind: Secret
apiVersion: v1
metadata:
  name: postgresql-credentials
data:
  # admin123
  postgresql-admin-password: YWRtaW4xMjM=
  # pippobaudo1234
  postgresql-password: cGlwcG9iYXVkbzEyMzQ=
  # user09M
  postgresql-user: dXNlcjA5TQ==
type: Opaque
---
# PostgreSQL StatefulSet
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql-db
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
            - name: PGDATA
              value: /data/pgdata
            - name: POSTGRES_DB
              value: keycloak
            - name: POSTGRES_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgresql-credentials
                  key: postgresql-admin-password
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgresql-credentials
                  key: postgresql-password
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: postgresql-credentials
                  key: postgresql-user
---
# PostgreSQL StatefulSet Service
apiVersion: v1
kind: Service
metadata:
  name: postgresql-service
spec:
  selector:
    app: postgresql-db
  type: LoadBalancer
  ports:
  - port: 5432
    targetPort: 5432
EOF

oc apply -f /tmp/PostgreSQL.yaml
```

Deploy a `Keycloak` instance:

```bash
OPENSHIFT_API_URL=$(oc config view --minify -o jsonpath='{.clusters[*].cluster.server}')
KEYCLOAK_HOSTNAME=$(echo $OPENSHIFT_API_URL | sed -e "s/^.*:\/\/api.\(.*\):.*/apps.\1/")

openssl req -newkey rsa:2048 -keyout key.pem -x509 -days 365 -out crt.pem -nodes -subj '/CN=keycloak.example.com'
oc create secret tls keycloak-tls-secret --cert=crt.pem --key=key.pem --namespace $NAMESPACE

cat <<EOF > /tmp/Keycloak.yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: basic-keycloak
spec:
  instances: 1
  hostname:
    hostname: basic-keycloak-$NAMESPACE.$KEYCLOAK_HOSTNAME
  ingress:
    enabled: true
  http:
    tlsSecret: keycloak-tls-secret
  db:
    vendor: postgres
    host: postgresql-service
    port: 5432
    database: keycloak
    usernameSecret:
      name: postgresql-credentials
      key: postgresql-user
    passwordSecret:
      name: postgresql-credentials
      key: postgresql-password
EOF

oc apply -f /tmp/Keycloak.yaml
```

After the Operator's POD as been deployed you might want to retrieve the credentials to access the Keycloak console as in the following:

```
oc get secrets/basic-keycloak-initial-admin -o jsonpath='{.data.username}' -n $NAMESPACE | base64 --decode
oc get secrets/basic-keycloak-initial-admin -o jsonpath='{.data.password}' -n $NAMESPACE | base64 --decode
```

Define a `KeycloakRealmImport`:

```
cat <<EOF > /tmp/KeycloakRealmImport.yaml
kind: KeycloakRealmImport
apiVersion: k8s.keycloak.org/v2alpha1
metadata:
  name: saml-basic-auth-import
  labels:
    app: sso
spec:
  keycloakCRName: basic-keycloak
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
EOF

oc apply -f /tmp/KeycloakRealmImport.yaml
```

in the `KeycloakRealmImport` definitions please note we define a user `client` which is required for EAP being able to register
a new SAML client into Keycloak;

==== keystore

When EAP, using the `client` user, registers a new SAML client into Keycloak, it needs to store in the Keycloak client
configuration, the SAML client's certificate;

On the other side, EAP needs to have the corresponding private key;

In order to create both the private key and the certificate, you have many options; two of these options are:

1. create a private key and a self-signed certificate manually and then store them in a JKS keystore:

   # Private Key and Self signed certificate
   keytool -genkeypair -alias saml-app \
   -storetype PKCS12 \
   -keyalg RSA -keysize 2048 \
   -keystore keystore.p12 -storepass password \
   -dname "CN=saml-basic-auth,OU=EAP SAML Client,O=Red Hat EAP QE,L=MB,S=Milan,C=IT" \
   -ext ku:c=dig,keyEncipherment \
   -validity 365
   # Import the PKCS12 file into a new java keystore
   keytool -importkeystore \
   -deststorepass password -destkeystore keystore.jks \
   -srckeystore keystore.p12 -srcstoretype PKCS12 -srcstorepass password

2. have Keycloak to do it for you; to do that, first configure a SAML client on Keycloak, and then download the keystore.jks file;
   the keystore will contain both the private key and the certificate you need;
   once you have downloaded the keystore, delete the SAML client: it's only needed to generate the keystore and EAP will
   create it automatically when it starts;
   when configuring the SAML client, use the following values:

   Archive Format:             JKS
   Key Alias:                  saml-app
   Key Password:               password
   Realm Certificate Alias:    saml-basic-auth
   Store Password:             password

NOTE: If you ever want to configure a new and complete SAML client (not one that's just needed to create a keystore), please note:
[1]: the `clientId` has to be set to the URL to web application you wish to protect with SAML,
[2]: the `adminUrl` actually populates the `Master SAML Processing URL` in the SAML client definition and is needed to properly have the client redirected back to the web application once authenticated

=== secret

Once you obtained a keystore (with one of the options above or in another way) use it to create a secret in OpenShift:

```
oc create secret generic eap-app-secret --from-file=keystore.jks=./keystore.jks --type=opaque -n $NAMESPACE
```

==== wildfly application

We are using an application configure to use the `eap-maven-plugin` to build EAP with base layer `cloud-default-config` + SAML layer `keycloak-saml`;

the `pom.xml` file should be configured as in the following:

```
        <profile>
            <id>openshift</id>
            <build>
                <plugins>
                    <plugin>
                        <groupId>org.jboss.eap.plugins</groupId>
                        <artifactId>eap-maven-plugin</artifactId>
                        <configuration>
                            <!-- some tests check for the provisioned galleon layers -->
                            <record-provisioning-state>true</record-provisioning-state>
                            <feature-packs>
                                <feature-pack>
                                    <location>wildfly@maven(org.jboss.universe:community-universe):current</location>
                                </feature-pack>
                                <feature-pack>
                                    <location>org.wildfly.cloud:wildfly-cloud-galleon-pack:2.0.0.Final</location>
                                </feature-pack>
                                <feature-pack>
                                    <groupId>org.keycloak</groupId>
                                    <artifactId>keycloak-saml-adapter-galleon-pack</artifactId>
                                    <version>999-SNAPSHOT</version> <!-- TODO: Update version when we know what it is -->
                                </feature-pack>
                            </feature-packs>
                            <layers>
                                <!-- this layer is smart enough to add the necessary configuration, as a startup cli -->
                                <layer>cloud-default-config</layer>
                                <!-- this layer adds the SAML adapter and dependencies to the modules directory -->
                                <layer>keycloak-saml</layer>
                            </layers>
                        </configuration>
                    </plugin>
                </plugins>
            </build>
        </profile>
```

then, in the `web.xml` file, you need to use `KEYCLOAK-SAML` as the `auth-method`, e.g.:

```
<web-app xmlns="http://java.sun.com/xml/ns/javaee"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://java.sun.com/xml/ns/javaee http://java.sun.com/xml/ns/javaee/web-app_3_0.xsd"
         version="3.0">
    <security-constraint>
        <web-resource-collection>
            <web-resource-name>app</web-resource-name>
            <url-pattern>/profile.jsp</url-pattern>
        </web-resource-collection>
        <auth-constraint>
            <role-name>user</role-name>
        </auth-constraint>
    </security-constraint>

    <login-config>
        <auth-method>KEYCLOAK-SAML</auth-method>
    </login-config>

    <security-role>
        <role-name>user</role-name>
    </security-role>
</web-app>
```

notice we also added a link to a protected resource `profile.jsp` which, once the user is authenticated, will show some user's data;
you can find the whole application here https://github.com/tommaso-borgato/eap-rhsso-saml-sso-example/tree/saml-feature-pack[eap-rhsso-saml-sso-example];

TODO: update to some official application if we have one;

==== wildfly build and deployment

We deploy EAP using EAP Helm charts;
We need a `values.yaml` file to customize EAP Helm charts;

Please note you have to configure a couple of values in the `values.yaml` file, based on your OpenShift cluster;

For example, if logged into the OpenShift cluster with the command `oc login https://api.my-cluster-base-url:6443 ...` then
you have to set:

```
export OPENSHIFT_CLUSTER_SUFFIX=my-cluster-base-url
```

The values that get configured based on the value of the `OPENSHIFT_CLUSTER_SUFFIX` variable are:

* `SSO_URL`: this is basically the "keycloak" Route created by the Keycloak Operator (note: no `/auth` suffix as in previous versions), e.g. https://keycloak-mytestns.apps.my-cluster-base-url; set its value with e.g.:

  KEYCLOAK_ROUTE=$(oc get route keycloak --template='{{ .spec.host }}')
  export SSO_URL=https://$KEYCLOAK_ROUTE

* `HOSTNAME_HTTPS`: this is basically the host part of the "my-release" Route that will be created by this HELM Chart for your application, e.g. `my-release-mytestns.apps.my-cluster-base-url`; set its value with e.g.:

  KEYCLOAK_ROUTE=$(oc get route keycloak --template='{{ .spec.host }}')
  export HOSTNAME_HTTPS=${KEYCLOAK_ROUTE//keycloak-/my-release-}

After setting these values we can create the `values.yaml` file;
```
KEYCLOAK_ROUTE=$(oc get ingress/basic-keycloak-ingress --template='{{ (index .spec.rules 0).host }}')
export SSO_URL=https://$KEYCLOAK_ROUTE

KEYCLOAK_ROUTE=$(oc get ingress/basic-keycloak-ingress --template='{{ (index .spec.rules 0).host }}')
export HOSTNAME_HTTPS=${KEYCLOAK_ROUTE//basic-keycloak-/my-release-}

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
    - name: HOSTNAME_HTTPS
      value: $HOSTNAME_HTTPS
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

And then we can use it to build and deploy our application:

```
helm repo add wildfly https://docs.wildfly.org/wildfly-charts/
helm install my-release -f /tmp/values.yaml wildfly/wildfly --namespace $NAMESPACE
```

Once the chained build completes and your application is deployed, you can try it out hitting "my-release" Route plus the
`/saml-app` context path, e.g. https://my-release-mytestns.apps.my-cluster-base-url/saml-app; you will be
redirected to Keycloak and asked for credentials, use username `user` and password `used` and you should finally get directed
to the secured resource `/saml-app/profile.jsp` e.g. https://my-release-mytestns.apps.my-cluster-base-url/saml-app/profile.jsp.