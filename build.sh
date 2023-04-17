#!/bin/bash
set -e

# These are the environment variables script expects to be set
# JAVA_HOME =
# ANDROID_HOME =

# ======= App settings =======
COMPILE_SDK_VERSION="31"
TARGET_SDK_VERSION="30"
MIN_SDK_VERSION="30"
BUILD_TOOLS_VERSION="30.0.3"
PACKAGE_NAME="com.example.hellonogradlejava"

# ======= Create intermediate directories =======
ROOT_PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )";
PROJECT_NAME=${ROOT_PROJECT_DIR##*/}
APP_PROJECT_DIR="${ROOT_PROJECT_DIR}/app"
APP_BUILD_DIR="$APP_PROJECT_DIR/build"
APP_INTERMEDIATES_DIR="$APP_BUILD_DIR/intermediates_"
APP_DEPS_DIR="$APP_BUILD_DIR/deps"
BUILD_DEPS_DIR="$APP_BUILD_DIR/build_deps"
MERGED_MANIFEST_DIR="$APP_INTERMEDIATES_DIR/merged_manifest"
APP_SOURCES_DIR="${APP_PROJECT_DIR}/src/main"
mkdir -p "${APP_BUILD_DIR}" "${APP_DEPS_DIR}" "${BUILD_DEPS_DIR}" "${MERGED_MANIFEST_DIR}"

# ======= Build tools =======
KEYTOOL="${JAVA_HOME}/bin/keytool"
AAPT2="$ANDROID_HOME/build-tools/${BUILD_TOOLS_VERSION}/aapt2"
D8="$ANDROID_HOME/build-tools/${BUILD_TOOLS_VERSION}/d8"
ZIPALIGN="$ANDROID_HOME/build-tools/${BUILD_TOOLS_VERSION}/zipalign"
JAVAC="${JAVA_HOME}/bin/javac"
APKSIGNER="$ANDROID_HOME/build-tools/${BUILD_TOOLS_VERSION}/apksigner"
ADB="${ANDROID_HOME}/platform-tools/adb"

# ======= Download all dependencies =======
echo "=== Downloading all dependencies..."
(cd "${BUILD_DEPS_DIR}" && xargs -t -n 1 curl -O -L -C- < ${APP_PROJECT_DIR}/build_deps.txt) || true
(cd "${APP_DEPS_DIR}" && xargs -t -n 1 curl -O -L -C- < ${APP_PROJECT_DIR}/deps.txt) || true

# ======= Prepare all .aar dependencies =======
echo "=== Preparing .aar dependencies..."
EXPLODED_AARS_DIR="$APP_INTERMEDIATES_DIR/exploded-aar"
for LIB in ${APP_DEPS_DIR}/*.aar; do
    LIB_NAME="$(basename $LIB)"
    echo "Unpacking $LIB_NAME"
    LIBDIR="${EXPLODED_AARS_DIR}/${LIB_NAME%.aar}"
    EX_LIBS+="${LIBDIR} "
    mkdir -p ${LIBDIR}
    unzip -qo ${LIB} -d ${LIBDIR}
    if [[ -f ${LIBDIR}/classes.jar ]]; then
        LIBS_JARS+=("${LIBDIR}/classes.jar")
    fi
    if [[ -f ${LIBDIR}/R.txt && -f ${LIBDIR}/AndroidManifest.xml && $(wc -l < "${LIBDIR}/R.txt") -gt 0 ]]; then
        LIB_PACKAGE="$(sed -nr 's/.*package=\"(.*)\".*/\1/p' "${LIBDIR}/AndroidManifest.xml")"
        R_FILE_PACKAGES+=("--extra-packages ${LIB_PACKAGE}")
        LIB_MANIFESTS+=("${LIBDIR}/AndroidManifest.xml")
    fi
    if [ "$(ls -A ${LIBDIR}/res 2> /dev/null)" ]; then
        LIBS_RES_AAPT+=("-S ${LIBDIR}/res")
    fi
done

for LIB in ${APP_DEPS_DIR}/*.jar; do
  LIBS_JARS+=("$LIB")
done

LIBS_JARS_STR="${LIBS_JARS[@]}"
LIB_MANIFESTS_STR="${LIB_MANIFESTS}"

# ======= Create a keystore =======
if [[ ! -f "${ROOT_PROJECT_DIR}/${PROJECT_NAME}.keystore" ]]; then
  echo "=== Creating keystore..."
  ${KEYTOOL} \
      -genkeypair \
      -validity 10000 \
      -dname "CN=com.example,
              OU=ANDROID_TRAINING,
              O=ANDROID,
              L=SomePlace,
              S=SomePlace,
              C=US" \
      -keystore "${ROOT_PROJECT_DIR}/${PROJECT_NAME}.keystore" \
      -storepass password \
      -keypass password \
      -alias ${PROJECT_NAME}Key \
      -keyalg RSA
fi

# ======= Process resources =======
echo "=== Compiling all resources ==="
FLAT_RES_DIR="$APP_INTERMEDIATES_DIR/flat_res"
GEN_SOURCES_DIR="${APP_BUILD_DIR}/generated_/source/r"
mkdir -p "${GEN_SOURCES_DIR}" "${FLAT_RES_DIR}"

# app resources
mkdir -p "$FLAT_RES_DIR/$PROJECT_NAME"
${AAPT2} compile \
      --dir "$APP_SOURCES_DIR/res" -o "$FLAT_RES_DIR/$PROJECT_NAME"

# libs resources
for LIB in $EXPLODED_AARS_DIR/*; do
  LIB_NAME="$(basename $LIB)"
  echo "Compiling res for $LIB_NAME"
  if [ -e "$LIB/res" ]; then
    mkdir -p "$FLAT_RES_DIR/$LIB_NAME"
    ${AAPT2} compile \
        --dir "$LIB/res" -o "$FLAT_RES_DIR/$LIB_NAME";
  fi
done

echo "=== Merging manifests ==="
for BUILD_LIB in $BUILD_DEPS_DIR/*; do
    BUILD_DEP_LIBS+=("$BUILD_LIB")
done
BUILD_JARS_STR="${BUILD_DEP_LIBS[@]}"
# run the manifest merger jar with its dependencies
java -cp "${BUILD_JARS_STR// /:}" com.android.manifmerger.Merger \
      --main "$APP_SOURCES_DIR/AndroidManifest.xml" \
      --libs ${LIB_MANIFESTS_STR// /:} \
      --property MIN_SDK_VERSION=${MIN_SDK_VERSION} \
      --out "$MERGED_MANIFEST_DIR/AndroidManifest.xml"

echo "=== Linking all resources ==="
APK_INTERMEDIATES_DIR="$APP_INTERMEDIATES_DIR/apk"
mkdir -p "$APK_INTERMEDIATES_DIR"
${AAPT2} link \
      --manifest "$MERGED_MANIFEST_DIR/AndroidManifest.xml" \
      --min-sdk-version ${MIN_SDK_VERSION} \
      --target-sdk-version ${TARGET_SDK_VERSION} \
      --version-code 1 \
      --version-name 1.0 \
      --auto-add-overlay \
      ${R_FILE_PACKAGES[@]} \
      -I "${ANDROID_HOME}/platforms/android-${COMPILE_SDK_VERSION}/android.jar" \
      -o "$APK_INTERMEDIATES_DIR/$PROJECT_NAME.noclasses.apk" \
      --java "$GEN_SOURCES_DIR" \
      $(find $FLAT_RES_DIR/ -name *.flat | sed 's/^/-R /')

# ======= Compiling app's .class files =======
echo "=== Compiling with javac..."
CLASSES_DIR="${APP_BUILD_DIR}/intermediates_/classes"
mkdir -p ${CLASSES_DIR}

${JAVAC} \
    -source 1.8 \
    -target 1.8 \
    -d "${CLASSES_DIR}" \
    -g \
    -classpath "${ANDROID_HOME}/platforms/android-${COMPILE_SDK_VERSION}/android.jar:${LIBS_JARS_STR// /:}" \
    $(find $APP_SOURCES_DIR/java -name '*.java') \
    $(find $GEN_SOURCES_DIR -name '*.java')

# ======= Create Main DEX list =======
MAIN_DEX_DIR="$APP_INTERMEDIATES_DIR/main_dex_list"
mkdir -p "$MAIN_DEX_DIR"
(cd "${CLASSES_DIR}" && find . -name '*Activity.class' | sed 's/^.\///g') > "$MAIN_DEX_DIR/main_dex_list.txt"

# ======= Compile .dex file =======
echo "=== Creating DEX files..."
DEX_DIR="${APP_BUILD_DIR}/intermediates_/dex"
mkdir -p ${DEX_DIR}

${D8} $(find "$CLASSES_DIR" -name *.class) \
    "${LIBS_JARS[@]}" \
    --debug \
    --main-dex-list "$MAIN_DEX_DIR/main_dex_list.txt" \
    --output "$DEX_DIR" \
    --lib "${ANDROID_HOME}/platforms/android-${COMPILE_SDK_VERSION}/android.jar"

# ======= Assemble a full apk =======
echo "=== Producing the full APK..."

cp "$APK_INTERMEDIATES_DIR/${PROJECT_NAME}.noclasses.apk" "$APK_INTERMEDIATES_DIR/${PROJECT_NAME}.unaligned.apk"
# Add classes*.dex files to intermediate apk built when linking the resources
for DEX_FILE in $(find $DEX_DIR -name 'classes*.dex'); do
  zip -uj "$APK_INTERMEDIATES_DIR/${PROJECT_NAME}.unaligned.apk" "$DEX_FILE"
done

# ======= Align the apk =======
echo "=== ZipAligning APK..."

${ZIPALIGN} \
    -p -f -v 4 \
    ${APK_INTERMEDIATES_DIR}/${PROJECT_NAME}.unaligned.apk \
    ${APK_INTERMEDIATES_DIR}/${PROJECT_NAME}.unsigned.apk

# ======= Sign the apk =======
echo "=== Signing the APK..."
OUTPUT_APK_DIR="${APP_BUILD_DIR}/outputs_/apk"
mkdir -p ${OUTPUT_APK_DIR}

${APKSIGNER} sign \
    --ks "${ROOT_PROJECT_DIR}/${PROJECT_NAME}.keystore" \
    --ks-key-alias "${PROJECT_NAME}Key" \
    --ks-pass pass:password \
    --in ${APK_INTERMEDIATES_DIR}/${PROJECT_NAME}.unsigned.apk \
    --out ${OUTPUT_APK_DIR}/${PROJECT_NAME}.apk

# ======= Install the app =======
echo "=== (Re)Installing the app"
${ADB} shell pm uninstall ${PACKAGE_NAME} || true
${ADB} install -r -g -d ${OUTPUT_APK_DIR}/${PROJECT_NAME}.apk

# ======= Launch the app =======
echo "=== Starting the app"
${ADB} \
    shell \
    am start ${PACKAGE_NAME}/.MainActivity
