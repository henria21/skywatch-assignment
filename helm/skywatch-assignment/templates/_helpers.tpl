{{- define "skywatch-assignment.rabbitEnv" -}}
- name: RABBITMQ_HOST
  value: {{ .Values.rabbitmqHost | quote }}
- name: RABBITMQ_USERNAME
  valueFrom: { secretKeyRef: { name: {{ .Values.secretName }}, key: rabbitmq-username } }
- name: RABBITMQ_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ .Values.secretName }}, key: rabbitmq-password } }
{{- end -}}
