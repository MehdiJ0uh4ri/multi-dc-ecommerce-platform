{{- define "data-tools.image" -}}
{{- required "image.tag is required (data-tools/VERSION)" .Values.image.tag | printf "%s:%s" .Values.image.repository -}}
{{- end }}

{{/* Settings every data-tools container needs to reach the platform. */}}
{{- define "data-tools.platformEnv" -}}
- name: GATEWAY_URL
  value: {{ .Values.platform.gatewayUrl | quote }}
- name: KEYCLOAK_URL
  value: {{ .Values.platform.keycloakUrl | quote }}
- name: KEYCLOAK_REALM
  value: {{ .Values.platform.realm | quote }}
- name: MAX_RPS
  value: {{ .Values.platform.maxRps | quote }}
{{- end }}

{{/* Shopper sign-up and order-context settings (seed-orders, loadgen). */}}
{{- define "data-tools.shopperEnv" -}}
- name: PUBLIC_CLIENT_ID
  value: {{ .Values.platform.publicClientId | quote }}
- name: DATA_TOOLS_USER_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.users }}
      key: password
- name: KAFKA_BOOTSTRAP
  value: {{ .Values.platform.kafkaBootstrap | quote }}
- name: ORDER_CONTEXT_TOPIC
  value: {{ .Values.platform.orderContextTopic | quote }}
- name: ORDER_CONTEXT_ENABLED
  value: {{ .Values.platform.orderContextEnabled | quote }}
{{- end }}

{{- define "data-tools.extraEnv" -}}
{{- range $name, $value := . }}
- name: {{ $name }}
  value: {{ $value | toString | quote }}
{{- end }}
{{- end }}

{{- define "data-tools.podSecurity" -}}
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  seccompProfile:
    type: RuntimeDefault
{{- end }}

{{- define "data-tools.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
{{- end }}
