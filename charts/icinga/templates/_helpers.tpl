{{- define "icinga.apiEnv" -}}
- name: ICINGA_TICKET_SALT
  valueFrom:
    secretKeyRef: { name: {{ .Values.apiSecret }}, key: ticket-salt }
- name: ICINGA_ROOT_API_PASSWORD
  valueFrom:
    secretKeyRef: { name: {{ .Values.apiSecret }}, key: root }
- name: ICINGA_ICINGAWEB_API_PASSWORD
  valueFrom:
    secretKeyRef: { name: {{ .Values.apiSecret }}, key: icingaweb }
{{- end -}}

{{- define "icinga.dbUser" -}}
valueFrom:
  secretKeyRef: { name: {{ .Values.database.secret }}, key: username }
{{- end -}}

{{- define "icinga.dbPassword" -}}
valueFrom:
  secretKeyRef: { name: {{ .Values.database.secret }}, key: password }
{{- end -}}
