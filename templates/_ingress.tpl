{{- define "springboot-template.ingress" -}}
{{- $ := .context }}
{{- $ingress := .ingress }}

{{- if semverCompare ">=1.19-0" $.Capabilities.KubeVersion.GitVersion -}}
apiVersion: networking.k8s.io/v1
{{- else if semverCompare ">=1.14-0" $.Capabilities.KubeVersion.GitVersion -}}
apiVersion: networking.k8s.io/v1beta1
{{- else -}}
apiVersion: extensions/v1beta1
{{- end }}



{{- $groupedRules := dict }}
{{- $groupedRulesPaths := dict }}
{{- $groupedRulesHosts := dict }}
{{- $groupedRulesPathsByHost := dict }} {{/* NEW: per-host paths for path-grouping */}}
{{- $groupedRulesFinal := dict }}
{{- $externalDnsHostList := dict }}
{{- if and $ingress.hosts $ingress.generateALBGroupedRules }}
{{- range $hostIndex, $hostValue := $ingress.hosts }}
  {{- $_ := set $externalDnsHostList $hostValue.host $hostValue.host }}
  {{- $pathsList := list  }}
  {{- range $pathIndex, $pathValue := $hostValue.paths }}
    {{- $servicePort := "" }}
    {{- $servicePortType := "" }}
    {{- if $pathValue.servicePortNumber }}
      {{- $servicePort = $pathValue.servicePortNumber }}
      {{- $servicePortType = "servicePortNumber" }}
    {{- else }}
      {{- $servicePort = $pathValue.servicePort }}
      {{- $servicePortType = "servicePort" }}
    {{- end }}
    {{- $groupName := print $pathValue.serviceName "-" $servicePort }}

    {{- if (hasKey $groupedRulesPaths $groupName) }}
      {{- $pathsList := get (get $groupedRulesPaths $groupName) "paths" }}
      {{- if not (has $pathValue.path $pathsList) }}
        {{- $pathsList = append $pathsList $pathValue.path }}
        {{- $groupedRulesPaths = set $groupedRulesPaths $groupName (dict "paths" $pathsList) }}
      {{- end }}
    {{- else }}
      {{- $groupedRulesPaths = set $groupedRulesPaths $groupName (dict "paths" (list $pathValue.path) ) }}
    {{- end }}
    {{- if (hasKey $groupedRulesHosts $groupName) }}
      {{- $hostsList := get (get $groupedRulesHosts $groupName) "hosts" }}
      {{- if not (has $hostValue.host $hostsList) }}
        {{- $hostsList = append $hostsList $hostValue.host }}
        {{- $groupedRulesHosts = set $groupedRulesHosts $groupName (dict "hosts" $hostsList) }}
      {{- end }}
    {{- else }}
      {{- $groupedRulesHosts = set $groupedRulesHosts $groupName (dict "hosts" (list $hostValue.host) ) }}
    {{- end }}

    {{- /* FIX: init using the *group* key (not literal "serviceName") */}}
    {{- if not (hasKey $groupedRules $groupName) }}
      {{- if $pathValue.pathType }}
        {{- $groupedRules = set $groupedRules $groupName (dict $servicePortType $servicePort "serviceName" $pathValue.serviceName "pathType" $pathValue.pathType) }}
      {{- else }}
        {{- $groupedRules = set $groupedRules $groupName (dict $servicePortType $servicePort "serviceName" $pathValue.serviceName) }}
      {{- end }}
    {{- end }}

    {{- /* NEW: per-host paths for this group */}}
    {{- $byHost := get $groupedRulesPathsByHost $groupName | default (dict) }}
    {{- $hostPaths := get $byHost $hostValue.host | default (list) }}
    {{- if not (has $pathValue.path $hostPaths) }}
      {{- $hostPaths = append $hostPaths $pathValue.path }}
    {{- end }}
    {{- $byHost = set $byHost $hostValue.host $hostPaths }}
    {{- $groupedRulesPathsByHost = set $groupedRulesPathsByHost $groupName $byHost }}

  {{- end }}
{{- end }}
{{- $groupedRules = merge $groupedRules $groupedRulesPaths $groupedRulesHosts }}
{{- end }}

{{- /* surface pathsByHost for render */}}
{{- $groupedRulesPathsByHostWrapped := dict }}
{{- range $gk, $v := $groupedRulesPathsByHost }}
  {{- $groupedRulesPathsByHostWrapped = set $groupedRulesPathsByHostWrapped $gk (dict "pathsByHost" $v) }}
{{- end }}
{{- $groupedRules = merge $groupedRules $groupedRulesPathsByHostWrapped }}

{{- if $ingress.groupedRules }}
{{- $groupedRulesFinal = (merge $groupedRules $ingress.groupedRules) }}
{{- else }}
{{- $groupedRulesFinal = $groupedRules }}
{{- end }}

kind: Ingress
metadata:
  name: {{ printf "%s%s" (include "ingress.name" .context) (default "" $ingress.nameSuffix) }}
  labels:
    {{- include "ingress.labels" .context | nindent 4 }}
  {{- if or ($ingress.annotations) ($groupedRulesFinal) ($externalDnsHostList) }}
  annotations:
    {{- with $ingress.annotations }}
    {{- tpl (toYaml .) $ | nindent 4 }}
    {{- end }}
    {{- if and ($externalDnsHostList) ($ingress.generateExternalDnsHostList) }}
    external-dns.alpha.kubernetes.io/hostname: {{ $externalDnsHostList | keys | sortAlpha | join "," }}
    {{- end }}

  {{- /* ALB actions/conditions */}}
  {{- range $groupName, $serviceData := $groupedRulesFinal }}
    {{- $mainLoopList := $serviceData.paths }}
    {{- $groupBy := "path" }}
    {{- if $serviceData.groupBy }}
      {{- if eq $serviceData.groupBy "host" }}
        {{- $groupBy = "host" }}
        {{- $mainLoopList = $serviceData.hosts }}
      {{- end }}
    {{- else }}
      {{- if gt (len $serviceData.hosts) (len $serviceData.paths) }}
        {{- $groupBy = "host" }}
        {{- $mainLoopList = $serviceData.hosts }}
      {{- end }}
    {{- end }}

    {{- if eq $groupBy "path" }}
      {{- /* Build per-host annotations; keep chunk size 4; skip-first to avoid duplicate path values */}}
      {{- range $hostIndex, $hostValue := $serviceData.hosts }}
        {{- $pathsForHost := get $serviceData.pathsByHost $hostValue }}
        {{- if not $pathsForHost }}{{- continue }}{{- end }}
        {{- $chunks := chunk 4 $pathsForHost }}
        {{- range $rulesIndex, $rulesList := $chunks }}
          {{- if gt (len $rulesList) 1 }}
    alb.ingress.kubernetes.io/actions.{{ tpl $groupName $ }}-h{{ $hostIndex }}-c{{ $rulesIndex }}: >-
      {
        "type": "forward",
        "forwardConfig": {
          "targetGroups": [
            {
              "serviceName": "{{ tpl $serviceData.serviceName $ }}",
              "servicePort": "{{ if $serviceData.servicePortNumber }}{{ tpl (toString $serviceData.servicePortNumber) $ }}{{ else }}{{ $serviceData.servicePort }}{{ end }}"
            }
          ]
        }
      }
    alb.ingress.kubernetes.io/conditions.{{ tpl $groupName $ }}-h{{ $hostIndex }}-c{{ $rulesIndex }}: >-
      [
        {
          "field": "path-pattern",
          "pathPatternConfig": {
            "values": [
              {{- $last := sub (len $rulesList) 1 }}
              {{- range $i, $p := $rulesList }}
                {{- if ne $i 0 }}
                "{{ tpl $p $ }}"{{ if ne $i $last }},{{ end }}
                {{- end }}
              {{- end }}
            ]
          }
        }
      ]
          {{- end }}
        {{- end }}
      {{- end }}
    {{- else }}
      {{- $serviceList := chunk 4 ($mainLoopList) }}
      {{- range $rulesIndex, $rulesList := $serviceList }}
    alb.ingress.kubernetes.io/actions.{{ tpl $groupName $ }}-{{ $rulesIndex }}: >-
      {
        "type": "forward",
        "forwardConfig": {
          "targetGroups": [
            {
              "serviceName": "{{ tpl $serviceData.serviceName $ }}",
              "servicePort": "{{ if $serviceData.servicePortNumber }}{{ tpl (toString $serviceData.servicePortNumber) $ }}{{ else }}{{ $serviceData.servicePort }}{{ end }}"
            }
          ]
        }
      }
    alb.ingress.kubernetes.io/conditions.{{ tpl $groupName $ }}-{{ $rulesIndex }}: >-
      [
        {
          "field": "host-header",
          "hostHeaderConfig": {
            "values": [
              {{- $last := sub (len $rulesList) 1 }}
              {{- range $index, $value := $rulesList }}
                {{- if ne $index 0 }}
                "{{ tpl $value $ }}"{{ if ne $index $last }},{{ end }}
                {{- end }}
              {{- end }}
            ]
          }
        }
      ]
      {{- end }}
    {{- end }}
  {{- end }}
  {{- end }}
spec:
  {{- if $ingress.tls }}
  tls:
    {{- range $ingress.tls }}
    - hosts:
        {{- range .hosts }}
        - {{ tpl . $ | quote }}
        {{- end }}
      secretName: {{ .secretName }}
    {{- end }}
  {{- end }}
  {{- if $ingress.ingressClassName }}
  ingressClassName: {{ $ingress.ingressClassName }}
  {{- end }}
  rules:
    {{- range $groupName, $serviceData := $groupedRulesFinal }}
    {{- $mainLoopList := $serviceData.paths }}
    {{- $groupBy := "path" }}
    {{- if $serviceData.groupBy }}
      {{- if eq $serviceData.groupBy "host" }}
        {{- $groupBy = "host" }}
        {{- $mainLoopList = $serviceData.hosts }}
      {{- end }}
    {{- else }}
      {{- if gt (len $serviceData.hosts) (len $serviceData.paths) }}
        {{- $groupBy = "host" }}
        {{- $mainLoopList = $serviceData.hosts }}
      {{- end }}
    {{- end }}
    {{- $mainList := chunk 4 ($mainLoopList) }}
    {{- if eq $groupBy "path"  }}
      {{- range $hostIndex, $hostValue := $serviceData.hosts }}
        {{- $pathsForHost := get $serviceData.pathsByHost $hostValue }}
        {{- if not $pathsForHost }}{{- continue }}{{- end }}
        {{- $chunks := chunk 4 $pathsForHost }}
        {{- range $pathIndex, $pathsList := $chunks }}
    - host: {{ $hostValue }}
      http:
        paths:
          - path: {{ first $pathsList }}
            pathType: {{ default "ImplementationSpecific" $serviceData.pathType }}
            backend:
              service:
                {{- if ne (len $pathsList) 1 }}
                name: {{ tpl $groupName $ }}-h{{ $hostIndex }}-c{{ $pathIndex }}
                port:
                  name: use-annotation
                {{- else }}
                name: {{ tpl $serviceData.serviceName $ }}
                port:
                  {{- if $serviceData.servicePortNumber }}
                  number: {{ tpl (toString $serviceData.servicePortNumber) $ }}
                  {{- else }}
                  name: {{ tpl (toString $serviceData.servicePort) $ }}
                  {{- end }}
                {{- end }}
        {{- end }}
      {{- end }}
    {{- else }}
      {{- range $hostIndex, $hostsList := $mainList }}
    - host: {{ first $hostsList }}
      http:
        paths:
          {{- range $pathIndex, $path := $serviceData.paths }}
          - path: {{ $path }}
            pathType: {{ default "ImplementationSpecific" $serviceData.pathType }}
            backend:
              service:
                {{- if ne (len $hostsList) 1 }}
                name: {{ tpl $groupName $ }}-{{ $hostIndex }}
                port:
                  name: use-annotation
                {{- else }}
                name: {{ tpl $serviceData.serviceName $ }}
                port:
                  {{- if $serviceData.servicePortNumber }}
                  number: {{ tpl (toString $serviceData.servicePortNumber) $ }}
                  {{- else }}
                  name: {{ tpl (toString $serviceData.servicePort) $ }}
                  {{- end }}
                {{- end }}
          {{- end }}
      {{- end }}
    {{- end }}
    {{- end }}

    {{- if not $ingress.generateALBGroupedRules }}
    {{- range $ingress.hosts }}
    - host: {{ tpl .host $ | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            {{- if semverCompare ">=1.19-0" $.Capabilities.KubeVersion.GitVersion }}
            pathType: {{ default "ImplementationSpecific" .pathType }}
            backend:
              service:
                name: {{ .serviceName }}
                port:
                  {{- if .servicePort }}
                  name: {{ .servicePort }}
                  {{- else if .servicePortNumber }}
                  number: {{ .servicePortNumber }}
                  {{- end }}
            {{- else }}
            backend:
              serviceName: {{ .serviceName }}
              servicePort: {{ .servicePort }}
            {{- end }}
          {{- end }}
    {{- end }}
    {{- end }}
{{- end }}

