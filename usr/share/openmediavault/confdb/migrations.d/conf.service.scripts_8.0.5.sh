#!/bin/sh
#
# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2024-2026 openmediavault plugin developers
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

set -e

. /etc/default/openmediavault
. /usr/share/openmediavault/scripts/helper-functions

# Add the emailonerror key to any existing scheduled jobs.
count=$(omv_config_get_count "/config/services/scripts/jobs/job")
index=1
while [ "${index}" -le "${count}" ]; do
  if ! omv_config_exists "/config/services/scripts/jobs/job[${index}]/emailonerror"; then
    omv_config_add_key "/config/services/scripts/jobs/job[${index}]" "emailonerror" "0"
  fi
  index=$((index + 1))
done

exit 0
