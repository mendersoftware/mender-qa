#!/bin/bash

set -e

PREV_REPORT=/prev-report
RESULTS=/results
NEW_REPORT=/report

if [ -d $PREV_REPORT/history ]; then
  cp -r $PREV_REPORT/history $RESULTS
else
  echo "WARNING: No history found in previous report"
fi

allure generate $RESULTS

cp -r /allure-report/* $NEW_REPORT
