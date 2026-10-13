#!/bin/sh

printf '%s\n' "$*" >>"${MOCK_STATE_DIR:?}/logger.log"
cat >>"${MOCK_STATE_DIR:?}/logger.log"
