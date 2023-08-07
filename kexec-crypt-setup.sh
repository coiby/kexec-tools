#!/bin/sh
#
	_devuuid=$(getarg kdump_luks_uuid=)

	if [[ -n $_devuuid ]]; then

		_key_desc=cryptsetup:$_devuuid-d0
		echo -n "$_key_desc" > /sys/kernel/crash_luks_volume_key
		printf -- '[ -e /dev/disk/by-id/dm-uuid-CRYPT-LUKS?-*-luks-%s ] || exit 1\n' $_devuuid" >> $hookdir/initqueue/finished/99-kdumpbase-crypt.sh"

		{
			printf -- 'ENV{ID_FS_UUID}=="%s", ' "$_devuuid"
			printf -- 'RUN+="%s --settled --unique --onetime ' "$(command -v initqueue)"
			printf -- '--name kdump-crypt-target-%%k %s ' "$(command -v cryptsetup)"
			printf -- 'luksOpen --volume-key-keyring %s $env{DEVNAME} %s"\n' "%user:$_key_desc" "luks-$_devuuid"
		} >> /etc/udev/rules.d/70-luks-kdump.rules
	fi
