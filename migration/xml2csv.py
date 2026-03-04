#!/usr/bin/env python3
"""
XML ↔ CSV Converter for repo manifest files
Usage:
  xml2csv.py [options] input.xml [output.csv]    # XML to CSV
  xml2csv.py [options] input.csv [output.xml]    # CSV to XML
  xml2csv.py roundtrip input.xml                 # Round-trip test

Options:
  --sort:COLUMN       Sort CSV by specified column (e.g., --sort:name)
  --remove:COLUMN     Remove specified column (e.g., --remove:revision)
  --remove:all        Remove all columns except 'name'
"""

import sys
import csv
import xml.etree.ElementTree as ET
from pathlib import Path

def xml2csv(xml_file, csv_file):
    """Convert XML manifest to CSV"""
    tree = ET.parse(xml_file)
    root = tree.getroot()

    # 모든 project 태그에서 사용된 속성 수집
    all_attrs = set()
    for project in root.findall('project'):
        all_attrs.update(project.attrib.keys())

    # 속성을 일관된 순서로 정렬 (name, path가 먼저)
    priority_attrs = ['name', 'path', 'remote', 'revision', 'groups']
    fieldnames = [attr for attr in priority_attrs if attr in all_attrs]
    fieldnames.extend(sorted(attr for attr in all_attrs if attr not in priority_attrs))

    with open(csv_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()

        for project in root.findall('project'):
            row = {field: project.get(field, '') for field in fieldnames}
            writer.writerow(row)

    count = len(root.findall('project'))
    print(f"\033[92m\033[1mSuccess({count} projects): XML → CSV\033[0m")
    print(f"{xml_file} → {csv_file}")
    return count

def csv2xml(csv_file, xml_file, template_xml=None):
    """Convert CSV back to XML manifest"""
    # template XML에서 remote 정보 추출
    remotes = []
    if template_xml and Path(template_xml).exists():
        tree = ET.parse(template_xml)
        root = tree.getroot()
        remotes = root.findall('remote')

    # 새 XML 생성
    manifest = ET.Element('manifest')

    # remote 태그 추가
    for remote in remotes:
        manifest.append(remote)

    # CSV 읽어서 project 태그 생성
    with open(csv_file, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        count = 0
        for row in reader:
            project = ET.SubElement(manifest, 'project')

            # 모든 속성 추가 (빈 값은 제외)
            for key, value in row.items():
                if value:  # 빈 문자열이 아닌 경우만
                    project.set(key, value)
            count += 1

    # XML 포매팅 및 저장
    indent(manifest)
    tree = ET.ElementTree(manifest)
    tree.write(xml_file, encoding='utf-8', xml_declaration=True)

    print(f"\033[92m\033[1mSuccess({count} projects): CSV → XML\033[0m")
    print(f"{csv_file} → {xml_file}")
    return count

def indent(elem, level=0):
    """XML 들여쓰기 (pretty print)"""
    i = "\n" + level * "  "
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = i + "  "
        if not elem.tail or not elem.tail.strip():
            elem.tail = i
        for child in elem:
            indent(child, level + 1)
        if not child.tail or not child.tail.strip():
            child.tail = i
    else:
        if level and (not elem.tail or not elem.tail.strip()):
            elem.tail = i

def compare_xml(xml1, xml2):
    """Compare two XML files"""
    tree1 = ET.parse(xml1)
    tree2 = ET.parse(xml2)

    projects1 = {p.get('name'): p.attrib for p in tree1.findall('.//project')}
    projects2 = {p.get('name'): p.attrib for p in tree2.findall('.//project')}

    print(f"\n=== Comparison: {xml1} vs {xml2} ===")
    print(f"  {xml1}: {len(projects1)} projects")
    print(f"  {xml2}: {len(projects2)} projects")

    # 프로젝트 이름 비교
    only_in_1 = set(projects1.keys()) - set(projects2.keys())
    only_in_2 = set(projects2.keys()) - set(projects1.keys())
    common = set(projects1.keys()) & set(projects2.keys())

    if only_in_1:
        print(f"\n  ✗ Only in {xml1}: {len(only_in_1)} projects")
        for name in list(only_in_1)[:5]:
            print(f"    - {name}")

    if only_in_2:
        print(f"\n  ✗ Only in {xml2}: {len(only_in_2)} projects")
        for name in list(only_in_2)[:5]:
            print(f"    - {name}")

    # 공통 프로젝트의 속성 비교
    diff_count = 0
    for name in sorted(common):
        if projects1[name] != projects2[name]:
            diff_count += 1
            if diff_count <= 5:  # 처음 5개만 출력
                print(f"\n  ✗ Difference in '{name}':")
                print(f"    {xml1}: {projects1[name]}")
                print(f"    {xml2}: {projects2[name]}")

    if diff_count > 5:
        print(f"\n  ... and {diff_count - 5} more differences")

    # 결과
    if not only_in_1 and not only_in_2 and diff_count == 0:
        print(f"\n  ✓✓✓ Files are IDENTICAL! ✓✓✓")
        return True
    else:
        print(f"\n  ✗ Files are DIFFERENT")
        print(f"    Projects only in {xml1}: {len(only_in_1)}")
        print(f"    Projects only in {xml2}: {len(only_in_2)}")
        print(f"    Projects with different attributes: {diff_count}")
        return False

def roundtrip(xml_file):
    """XML → CSV → XML 왕복 변환 및 비교"""
    csv_file = xml_file.replace('.xml', '.csv')
    xml2_file = xml_file.replace('.xml', '2.xml')

    print("=== Round-trip conversion test ===\n")
    print(f"Step 1: {xml_file} → {csv_file}")
    xml2csv(xml_file, csv_file)

    print(f"\nStep 2: {csv_file} → {xml2_file}")
    csv2xml(csv_file, xml2_file, template_xml=xml_file)

    print(f"\nStep 3: Compare {xml_file} vs {xml2_file}")
    result = compare_xml(xml_file, xml2_file)

    return result

def process_csv_options(csv_file, options):
    """Apply options to CSV file (sort, remove columns)"""
    if not options:
        return

    # CSV 파일 읽기
    with open(csv_file, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        fieldnames = reader.fieldnames

    # 옵션 처리
    for option in options:
        if option.startswith('--sort:'):
            sort_column = option.split(':', 1)[1]
            if sort_column in fieldnames:
                rows.sort(key=lambda x: x.get(sort_column, ''))
                print(f"  • Sorted by: {sort_column}")
            else:
                print(f"  ⚠ Warning: Column '{sort_column}' not found, skipping sort")

        elif option.startswith('--remove:'):
            target = option.split(':', 1)[1]
            if target == 'all':
                # name만 남기고 모두 삭제
                fieldnames = ['name']
                print(f"  • Removed all columns except 'name'")
            else:
                # 특정 컬럼 삭제
                if target in fieldnames:
                    fieldnames = [f for f in fieldnames if f != target]
                    print(f"  • Removed column: {target}")
                else:
                    print(f"  ⚠ Warning: Column '{target}' not found, skipping remove")

    # 수정된 CSV 파일 쓰기
    with open(csv_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            filtered_row = {k: v for k, v in row.items() if k in fieldnames}
            writer.writerow(filtered_row)

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    # 옵션과 파일명 분리
    options = []
    files = []
    for arg in sys.argv[1:]:
        if arg.startswith('--'):
            options.append(arg)
        else:
            files.append(arg)

    # roundtrip 명령은 유지
    if files and files[0] == 'roundtrip':
        if len(files) != 2:
            print("Usage: xml2csv.py roundtrip input.xml")
            sys.exit(1)
        success = roundtrip(files[1])
        sys.exit(0 if success else 1)

    # 최소 하나의 입력 파일 필요
    if not files:
        print("Error: No input file specified")
        print(__doc__)
        sys.exit(1)

    input_file = files[0]

    if not Path(input_file).exists():
        print(f"Error: File not found: {input_file}")
        sys.exit(1)

    # 출력 파일이 지정되지 않으면 확장자만 바꿔서 생성
    if len(files) >= 2:
        output_file = files[1]
    else:
        if input_file.endswith('.xml'):
            output_file = input_file.replace('.xml', '.csv')
        elif input_file.endswith('.csv'):
            output_file = input_file.replace('.csv', '.xml')
        else:
            print("Error: Input file must be .xml or .csv")
            sys.exit(1)

    # 확장자로 변환 방향 결정
    if input_file.endswith('.xml'):
        xml2csv(input_file, output_file)
        # CSV 파일에 옵션 적용
        process_csv_options(output_file, options)
    elif input_file.endswith('.csv'):
        # CSV 파일에 먼저 옵션 적용
        process_csv_options(input_file, options)
        # template XML은 입력 파일명에서 .csv를 .xml로 바꾼 파일 사용
        template = input_file.replace('.csv', '.xml')
        if not Path(template).exists():
            template = None
        csv2xml(input_file, output_file, template)
    else:
        print("Error: Input file must be .xml or .csv")
        sys.exit(1)

if __name__ == '__main__':
    main()
