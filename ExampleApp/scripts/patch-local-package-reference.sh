#!/usr/bin/env bash
set -euo pipefail

pbxproj_path="${1:-ExampleApp/ExampleApp.xcodeproj/project.pbxproj}"
package_ref_id="${PACKAGE_REF_ID:-0A11C0CA1A11C0CA1A11C0CA}"
package_ref_comment='XCLocalSwiftPackageReference ".."'
package_ref_entry="${package_ref_id} /* ${package_ref_comment} */"
package_assignment="package = ${package_ref_entry};"

if [[ ! -f "$pbxproj_path" ]]; then
  echo "pbxproj not found: $pbxproj_path" >&2
  exit 1
fi

if ! grep -q 'packageReferences = (' "$pbxproj_path"; then
  perl -0777 -i -pe "s@(mainGroup = [A-F0-9]+;\n)@\${1}\t\t\t\tpackageReferences = (\n\t\t\t\t\t${package_ref_entry},\n\t\t\t\t);\n@s;" "$pbxproj_path"
elif ! grep -Fq "$package_ref_entry" "$pbxproj_path"; then
  perl -0777 -i -pe "s@(packageReferences = \(\n)@\${1}\t\t\t\t\t${package_ref_entry},\n@s;" "$pbxproj_path"
fi

if ! grep -q 'Begin XCLocalSwiftPackageReference section' "$pbxproj_path"; then
  perl -0777 -i -pe "s@(/\* End XCSwiftPackageProductDependency section \*/\n)@\t/* Begin XCLocalSwiftPackageReference section */\n\t\t${package_ref_entry} = {\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = ..;\n\t\t};\n\t/* End XCLocalSwiftPackageReference section */\n\t\$1@s;" "$pbxproj_path"
fi

perl -0777 -i -pe "s@(\n\t\t[0-9A-F]+ /\* [^*]+ \*/ = \{\n\t\t\tisa = XCSwiftPackageProductDependency;\n)\t\t\tpackage = [^\n]*\n(\t\t\tproductName = Apus;\n)@\${1}\t\t\t${package_assignment}\n\${2}@gs;" "$pbxproj_path"
perl -0777 -i -pe "s@(\n\t\t[0-9A-F]+ /\* [^*]+ \*/ = \{\n\t\t\tisa = XCSwiftPackageProductDependency;\n)(?!\t\t\tpackage = [^\n]*\n)(\t\t\tproductName = Apus;\n)@\${1}\t\t\t${package_assignment}\n\${2}@gs;" "$pbxproj_path"

if ! grep -q 'Begin XCLocalSwiftPackageReference section' "$pbxproj_path"; then
  echo "Failed to add local package reference section to $pbxproj_path" >&2
  exit 1
fi

if ! grep -Fq "$package_ref_entry" "$pbxproj_path"; then
  echo "Failed to add package reference entry to $pbxproj_path" >&2
  exit 1
fi

apus_products_count="$(grep -c 'productName = Apus;' "$pbxproj_path" || true)"
package_assignment_count="$(grep -Fc "$package_assignment" "$pbxproj_path" || true)"
if [[ "$apus_products_count" -eq 0 ]]; then
  echo "No Apus package product dependencies found in $pbxproj_path" >&2
  exit 1
fi

if [[ "$package_assignment_count" -lt "$apus_products_count" ]]; then
  echo "Failed to link all Apus package products to local package reference in $pbxproj_path" >&2
  exit 1
fi

if ! grep -q 'packageReferences = (' "$pbxproj_path"; then
  echo "Failed to add packageReferences block to $pbxproj_path" >&2
  exit 1
fi

if ! grep -Fq "$package_assignment" "$pbxproj_path"; then
  echo "Failed to add local package reference to $pbxproj_path" >&2
  exit 1
fi
