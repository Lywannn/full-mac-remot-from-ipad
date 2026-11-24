-- __IPADMODE_CLI__ is replaced with the absolute CLI path by scripts/build-app.sh.
-- Exit 1 (refused) and 2 (failed) are already shown by the daemon's notice panel; only other codes get a dialog.
set cli to "__IPADMODE_CLI__"
try
  do shell script quoted form of cli & " normal"
on error errMsg number errNum
  if errNum is not in {1, 2} then
    display dialog errMsg buttons {"OK"} default button 1 with title "Layar Normal" with icon caution giving up after 20
  end if
end try
