#!/usr/bin/python3
# -*- coding: utf-8 -*-

import hashlib
import ipaddress
import json
import os
import shutil
import signal
from collections import OrderedDict
from configparser import ConfigParser

import requests


class CaseSensitiveConfigParser(ConfigParser):
    """
    使用 OrderedDict 来保持原始的大小写
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs, dict_type=OrderedDict, strict=False)

    def optionxform(self, optionstr):
        return optionstr  # 返回原始的键名，不进行小写转换


class Convert2QX:
    MY_REPO_PREFIX = "https://mirror.ghproxy.com/https://raw.githubusercontent.com/Regan-He/ACL4SSR/main"
    NO_RESOLVE = "NO-RESOLVE"
    KNOWN_FORCE_POLICY = ["DIRECT", "REJECT"]
    KNOWN_THIRD_PARTY_POLICY_NAME = [
        "TIKTOK",
        "YOUTUBE",
        # Apple Services
        "APPLETV",
        # ChatGPT
        "OPENAI",
        # Microsoft Services
        "TEAMS",
        # Google Services
        "CHROMECAST",
        "GOOGLEDRIVE",
        "GOOGLESEARCH",
        "GOOGLEVOICE",
        # Foreign media
        "DISNEY",
        "INSTAGRAM",
        "NETFLIX",
        "TWITCH",
        # AD
        "ADVERTISING",
        "ADVERTISINGLITE",
        "ADVERTISINGMITV",
        "HIJACKING",
        "PRIVATETRACKER"
    ]
    QX_DIR_PREFIX = "QuantumultX"

    RULE_MAPPING = {"DOMAIN": "HOST", "DOMAIN-SUFFIX": "HOST-SUFFIX", "DOMAIN-KEYWORD": "HOST-KEYWORD"}

    def __init__(self, rule_file=None, rule_checksum_file=None, qx_conf=None, tmp_dir=None):
        self._rule_file = rule_file or os.path.join(Convert2QX.QX_DIR_PREFIX, "ClashRule.conf")
        self._rule_checksum_file = rule_checksum_file or os.path.join(Convert2QX.QX_DIR_PREFIX, "ClashRule-lock.json")
        self._qx_conf = qx_conf or os.path.join(Convert2QX.QX_DIR_PREFIX, "filter_remote.conf")
        self._qx_tmp_dir = tmp_dir or os.path.join(Convert2QX.QX_DIR_PREFIX, "tmp")
        self._qx_tmp_file = os.path.join(self._qx_tmp_dir, "process_conf.list")
        self._config = None
        self._checksum_dict = None
        self._error_found = False
        self._changed_count = 0

    def _set_increase(self):
        self._changed_count += 1

    def _get_increase(self):
        return self._changed_count

    def _load_conf(self):
        self._config = CaseSensitiveConfigParser()
        self._config.read(self._rule_file)

    def _load_conf_lock(self):
        with open(self._rule_checksum_file, "r") as file:
            self._checksum_dict = json.load(file)

    def _remote_rule_nochange(self, file_name, local_rule_file):
        with open(file_name, "rb") as file:
            sha256_hash = hashlib.sha256(file.read()).hexdigest()
        checksum_in_dict = self._checksum_dict.get(local_rule_file)
        if checksum_in_dict and checksum_in_dict == sha256_hash:
            return True  # Not Changed
        self._checksum_dict[local_rule_file] = sha256_hash
        self._set_increase()
        return False  # Changed

    def _get_remote_rule(self, orig_url):
        response = requests.get(orig_url)
        response.raise_for_status()  # 确保请求成功
        with open(self._qx_tmp_file, "w", encoding="utf-8") as temp_file:
            temp_file.write(response.text)
        return True

    def __sort_key(rule):
        parts = rule.split(",")
        if parts[0] == "IP-CIDR":
            return (parts[0], ipaddress.ip_network(parts[1], strict=False))
        else:
            return (parts[0], parts[1])

    def __reset_rule_type(orig):
        if orig in Convert2QX.RULE_MAPPING.keys():
            return Convert2QX.RULE_MAPPING[orig]
        else:
            return orig

    def _convert_qx_rule(self, remote, tag, result):
        """
        如果远端文件没有修改，则返回0，否则返回1
        """
        if not self._get_remote_rule(remote):
            print(f"Failed to get remote rule {tag}: {remote}")
            return
        if self._remote_rule_nochange(self._qx_tmp_file, result):
            print(f"Skip processing {tag}: {remote}")
            return
        print(f"Start processing {tag}: {remote}")

        full_file_name = os.path.abspath(result)
        full_file_path = os.path.dirname(full_file_name)
        os.makedirs(full_file_path, exist_ok=True)

        unknown_policy_names = set()
        new_qx_rules = set()
        with open(self._qx_tmp_file, "r", encoding="utf-8") as file:
            for line in file:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(",")
                rule_type = Convert2QX.__reset_rule_type(parts[0].strip().upper())
                domain_name = parts[1].strip()
                policy_name = parts[2].strip().upper() if len(parts) > 2 else tag
                if policy_name == tag:
                    pass
                elif policy_name == Convert2QX.NO_RESOLVE:
                    policy_name = f"{tag},{Convert2QX.NO_RESOLVE.lower()}"
                elif policy_name in Convert2QX.KNOWN_FORCE_POLICY:
                    # 已知的direct和reject策略，不能使用策略名前缀，必须保持其已知策略。
                    pass
                elif policy_name in Convert2QX.KNOWN_THIRD_PARTY_POLICY_NAME:
                    policy_name = tag
                else:
                    unknown_policy_names.add(policy_name)
                    policy_name = tag
                new_qx_rules.add(f"{rule_type},{domain_name},{policy_name}")

        if len(unknown_policy_names):
            unknown_policy = sorted(unknown_policy_names)
            print(f"Found unknown policy names {unknown_policy} from {tag}: {remote}")

        o_qx_rules = sorted(new_qx_rules, key=Convert2QX.__sort_key)
        with open(full_file_name, "w", encoding="utf-8") as output_file:
            output_file.write("\n".join(o_qx_rules + [""]))


    def _process_section(self, tag, content):
        rule_in_section = []
        for name in content:
            if name.lower() == "level":
                continue
            local_rule_file = os.path.join(Convert2QX.QX_DIR_PREFIX, name)
            remote_file_url = content[name]
            self._convert_qx_rule(remote_file_url, tag, local_rule_file)
            output_line = (
                f"{Convert2QX.MY_REPO_PREFIX}/{local_rule_file}, "
                f"tag={tag}, force-policy={tag}, update-interval=86400, opt-parser=true, enabled=true"
            )
            rule_in_section.append(output_line)
        return rule_in_section

    def _update_qx_conf(self, latest_filter_remote):
        if not self._get_increase():
            print(f"No need to update {self._qx_conf}")
            return
        if self._error_found:
            print(f"Error found when getting remote rules, no need to update {self._qx_conf}")
            return
        print(f"{self._get_increase()} rules need to be updated")

        with open(self._qx_conf, "w", encoding="utf-8") as f:
            f.write("\n".join(latest_filter_remote))
        with open(self._rule_checksum_file, "w", encoding="utf-8") as file:
            json.dump(self._checksum_dict, file, ensure_ascii=False, indent=4, sort_keys=True)

    def _prepare(self):
        os.makedirs(self._qx_tmp_dir, exist_ok=True)

    def init(self):
        self._prepare()
        self._load_conf()
        self._load_conf_lock()

    def check(self):
        return bool(self._config is not None and self._checksum_dict is not None)

    def run(self):
        latest_filter_remote = []
        for section in self._config.sections():
            output_lines = self._process_section(section, self._config[section])
            latest_filter_remote.extend(output_lines)
        self._update_qx_conf(latest_filter_remote)

    def clean(self):
        if os.path.exists(self._qx_tmp_dir):
            shutil.rmtree(self._qx_tmp_dir)

    def exit_clean(self, signum, frame):
        print("Signal handler called with signal " + str(signum))
        self.clean()
        exit(0)


def main():
    converter = Convert2QX()
    converter.init()
    signal.signal(signal.SIGINT, converter.exit_clean)
    signal.signal(signal.SIGTERM, converter.exit_clean)
    if converter.check():
        converter.run()
        converter.clean()
    else:
        print("Convert2QX is invalid")


if __name__ == "__main__":
    main()
