#!/usr/bin/python3
# -*- coding: utf-8 -*-

import configparser

QX_FILTER_REMOTE_MAPPING='filter-remote-mapping.conf'
QX_FILTER_REMOTE_CONF="qx_filter_remote.conf"
MY_REPO_PREFIX='https://fastly.jsdelivr.net/gh/Regan-He/ACL4SSR@main'

def read_ini_config(filename):
    # 创建配置解析器
    config = configparser.ConfigParser()
    # 读取配置文件
    config.read(filename)
    return config

def extract_path_and_filename(url):
    # 首先去除协议部分 (https://)
    path_start = url.find('/gh/') + 4  # +4 为了跳过 '/gh/'
    # 获取路径和文件名部分
    path_and_file = url[path_start:]
    # 分割最后一个 '/' 以分离文件名和路径
    path_parts = path_and_file.rsplit('/', 1)
    file_path = path_parts[0]  # 路径部分
    file_name = path_parts[1]  # 文件名部分

    return file_path, file_name

def process_section(tag_name, tag_content):
    for url_k in tag_content:
        orig_url =tag_content[url_k]
        output_suffix=f'tag={tag_name}, update-interval=86400, opt-parser=true, enabled=true'
        file_path,file_name=extract_path_and_filename(orig_url)
        output_line=f'{MY_REPO_PREFIX}/{file_path}/{file_name}, {output_suffix}'
        # 将output_line写入qx_filter_remote.conf
        with open(QX_FILTER_REMOTE_CONF, 'a') as f:
            f.write(output_line + '\n')

def main():
    # 读取并解析配置文件
    config = read_ini_config(QX_FILTER_REMOTE_MAPPING)
    # 打印出读取的配置，用于验证（可根据需要删除或修改此部分）
    for section in config.sections():
        tag_name=section
        tag_content=config[section]
        process_section(tag_name, tag_content)

if __name__ == '__main__':
    main()
