# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2024-2025 OpenMediaVault Plugin Developers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

{% set config = salt['omv_conf.get']('conf.service.scripts') %}
{% if config.sharedfolderref | length > 0 %}
{% set sfpath = salt['omv_conf.get_sharedfolder_path'](config.sharedfolderref).rstrip('/') %}

{% for file in config.files.file %}
{% set scriptFile = sfpath ~ '/' ~ file.name ~ '.' ~ file.ext %}

configure_scriptfile_{{ file.name }}:
  file.managed:
    - name: '{{ scriptFile }}'
    - source:
      - salt://{{ tpldir }}/files/script.j2
    - template: jinja
    - context:
        file: {{ file | json }}
    - user: '{{ config.scriptsowner }}'
    - group: '{{ config.scriptsgroup }}'
    - mode: '{{ config.fileperms }}'

{% endfor %}

{% set jobs = salt['omv_conf.get']('conf.service.scripts.job') %}

configure_scripts_scheduled_jobs:
  file.managed:
    - name: '/etc/cron.d/omv-scripts-jobs'
    - source:
      - salt://{{ tpldir }}/files/jobs.j2
    - template: jinja
    - context:
        jobs: {{ jobs | json }}
        sfpath: {{ sfpath }}
    - user: root
    - group: root
    - mode: 644

{% endif %}

configure_scripts_log_rotation:
  file.managed:
    - name: '/etc/logrotate.d/omv-scripts-exec-wrapper-logs'
    - source:
      - salt://{{ tpldir }}/files/logrotate.j2
    - template: jinja
    - context:
        logretentionlength: {{ config.logretentionlength }}
        logretentiontype: {{ config.logretentiontype }}
    - user: root
    - group: root
    - mode: 644

configure_scripts_log_rotation_file:
  file.touch:
    - name: "/var/log/omv-scripts-exec-tracker/dummy"
