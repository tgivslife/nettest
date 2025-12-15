#!/bin/bash

# Script to copy Rust library to app bundle Frameworks
LIB_SOURCE="$PROJECT_DIR/Runner/Frameworks/libnettest.dylib"
LIB_DEST="$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app/Contents/Frameworks/libnettest.dylib"

if [ -f "$LIB_SOURCE" ]; then
    echo "Copying libnettest.dylib to app bundle..."
    mkdir -p "$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app/Contents/Frameworks"
    cp "$LIB_SOURCE" "$LIB_DEST"
    
    # Fix install name
    install_name_tool -id @rpath/libnettest.dylib "$LIB_DEST" 2>/dev/null || true
    
    echo "Library copied successfully to $LIB_DEST"
else
    echo "Warning: libnettest.dylib not found at $LIB_SOURCE"
fi

