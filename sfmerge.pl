#!/usr/bin/perl
# Copyright (c) 2021 Tomek Wardega
#
# 9/12/2021 Tomek Wardega: Initial version of compare and merge
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
use feature qw(fc);
use Config::Std;
use Cwd;
use Data::Dumper;
use Getopt::Long;
use File::Basename;
use File::Copy;
use File::Path qw(make_path);
use Text::CSV;
use Digest::MD5 qw(md5_hex);
use Digest::MD5::File qw(file_md5_hex);
use IO::Prompt::Tiny qw(prompt);
use File::Find;

#
# Read command line arguments
$confFn = 'sfmerge.cfg';
$debug = 0;
$report = 0;
$delta = 0;
$diffCsv = '';
GetOptions(
	"config=s" => \$confFn, # config file name, using Config::Std syntax
	"debug" => \$debug, # flag, show debug messages
	"report" => \$report, # flag, report mode indicator
	"delta" => \$delta, # flag, create a delta package
	"diff=s" => \$diffCsv # diff file name
	);

# Read current working dir
our $currentWorkingDir = cwd();

# Read config file
our $cfgRef;
if (-e "$confFn") {
	read_config($confFn, $cfgRef);
}

# Set defaults, if config file is not found
$cfgRef->{''}->{'sort'} //= ['<name>','<fullName>'];
$cfgRef->{''}->{'diffKeySeparator'} //= "\036";
$cfgRef->{''}->{'reportMode'} //= $report;

# Set diff key separator as a global variable, to be able to access in global scope
our $diffSep = $cfgRef->{''}->{'diffKeySeparator'};

# Set the SF api version for delta package generator
# NOTE: this should match the version of metadata stored in the repo
our $pckgGenVersion = $cfgRef->{''}->{'package-gen-version'} // '53.0';

# Create a string listing all sub-folders for metadata diff/merge checks, separated by $sKey$diffSep
# NOTE: Top level folder "." is automatically added to this list
our $mergeDirs = "$diffSep." . GetConsolidatedList($cfgRef->{''}->{'merge'} // '', $diffSep);

# Create a string listing all folders where #OVERWRITE# should be applied i.e.
# if a file are different in source folder comparing to the file in the target folder,
# or if the file does not exist in the target folder - the 'source' version
# of the file should be copied to its analogous place in the target folder
our $overwrites = GetConsolidatedList($cfgRef->{''}->{'overwrite'} // '', $diffSep);

# Create an list with all file-name prefixes to exclude from comparisons
# E.g. package - to exclude package.xml file
our @excludeList = split(/$diffSep/, GetConsolidatedList($cfgRef->{''}->{'excludeFiles'} // '', $diffSep));

# Reports related data will be stored here...
our $rptRef = {};
$rptRef->{'HEADER'}->{ 'DIFFHEADER' } = [ 'Developer Work Log Name', 'Request Time Stamp',
'Work Team', 'Developer Name', 'User Story', 'Merge Action',
'Metadata', 'Path', 'L1 Key', 'L2 Key', 'L3 Key', 'L4 Key'
];
$rptRef->{'HEADER'}->{ 'DIFFHEADER2' } = [ 'Developer Work Log Name', 'Request Time Stamp',
'Work Team', 'Developer Name', 'User Story', 'Merge Action',
'Metadata', 'Path', 'L1 Key', 'L2 Key', 'L3 Key', 'L4 Key'
];
$rptRef->{ 'CURRENT' }->{ 'MERGE_ACTIONS' } = {}; # Initialize merge-actions
# Sanity check of the 'diff' file
if ($diffCsv ne '') {
	if (!-f $diffCsv) {
		print "Diff file $diffCsv does not exist - please review the file path and try again...\n";
		exit;
	} else {
		$rptRef->{CURRENT}->{DIFF_FILE_NAME} = $diffCsv;
	}
}

# Information about files in the source folder (name + whether the contents should
# be overwritten or merged) will be stored here...
our $srcFileRef = {};

our $srcFld //= $ARGV[0];
our $trgFld //= $ARGV[1];
if ($trgFld ne '' && $srcFld ne '') {
	if ($diffCsv eq '') {
		# Prompt for:
		# - work team name
		# - developer name
		# - user story number(s)
		do {$cfgRef->{''}->{'workTeamName'} = prompt("Work team name:", $cfgRef->{''}->{'workTeamName'} // '')} until ($cfgRef->{''}->{'workTeamName'} ne '');
		do {$cfgRef->{''}->{'developerName'} = prompt("Developer name:", $cfgRef->{''}->{'developerName'} // '')} until ($cfgRef->{''}->{'developerName'} ne '');
		do {$cfgRef->{''}->{'userStories'} = prompt("User story:")} until ($cfgRef->{''}->{'userStories'} ne '');
		my $go = prompt("Proceed with file comparison? [y/n]", 'y');
		exit if (lc($go) ne 'y');

		# When you compare files in folders, always generate report
		$cfgRef->{''}->{'reportMode'} = 1;
		my $flRef = [];
		foreach my $fld (@ARGV) {
			push(@$flRef, $fld);
		}
		CompareFiles($srcFld, $flRef, $cfgRef, $rptRef);
		$diffCsv = $rptRef->{ 'CURRENT' }->{ 'DIFF_FILE_NAME' };
		print "Diff file $diffCsv has been successfully created...\n\n";
	}

	$go = prompt("Proceed with file merge? [y/n]", 'y');
	exit if (lc($go) ne 'y');

	$cfgRef->{''}->{'reportMode'} = 0;
	my $mergeLogRef = MergeFiles($srcFld, $trgFld, $cfgRef, $rptRef);

	$go = prompt("Proceed with preparing delta deployment package? [y/n]", 'y');
	exit if (lc($go) ne 'y');
	print "Package generated for metadata API version $pckgGenVersion...\n";
	# for this last step in the process: the source for preparing the delta
	# package are files in the target folder, so $srcFld = $trgFld
	$srcFld = $trgFld;
	PrepDeltaPackage($srcFld, $cfgRef, $rptRef);
} elsif ($srcFld ne '') {
	if ($diffCsv eq '') {
		SortFiles($srcFld, $cfgRef, $rptRef);
	} else {
		$go = prompt("Proceed with preparing delta deployment package? [y/n]", 'y');
		exit if (lc($go) ne 'y');
		print "Package generated for metadata API version $pckgGenVersion...\n";
		PrepDeltaPackage($srcFld, $cfgRef, $rptRef);
	}

}  else {
	# diplay help message and exit - if help flag specified
	print <<End;
Usage:

sfmerge [--config=<path_to_config_file>] [--diff=<path_to_diff_file] <source_folder> <target_folder>

Compare salesforce metadata files in the <source_folder> with metadata files in
the <target_folder> and merge changes, the resulting CSV diff file is created in a folder SfmergeReports
where sfmerge program resides (folder location may be also specified in the config file):

If <path_to_config_file> is not specified on the command line, the script
looks for a file sfmerge.cfg in the current working directory.

Optional parameter --diff=<path_to_diff_file> allows to execute just the 'merge' phase
of the operation, assuming that the previous run executed the diff file and was stopped
before merge occurred.

End
	exit;
}

sub GetConsolidatedList {
	my ($opt, $sep) = @_;
	my $ret = $sep;
	if (ref($opt) eq 'ARRAY') {
		foreach my $item (@$opt) {
			$item =~ s/\s+/$sep/g;
			$ret .= "$item$sep";
		}
	} else {
		$opt =~ s/\s+/$sep/g;
		$ret .= "$opt$sep";
	}
	return $ret;
}

sub ExcludedFileCheck {
	my ($fn) = @_;
	my $ret = 0;
	foreach my $item (@excludeList) {
		if ($item ne '' && index($fn, $item) == 0) {
			$ret = 1;
			last;
		}
	}
	$ret;
}

sub GetMetadataInfo {
	my ($dir, $fn) = @_;
	my ($ret, $opt, $i, $item, $pos, @map);
	$ret = '';
	$pos = index($dir, '/');
	if ($pos > 0) {
		$dir = substr($dir, 0, $pos);
	}
	if (defined($cfgRef->{''}->{"metadatamap-$dir"})) {
		$opt = $cfgRef->{''}->{"metadatamap-$dir"};
		if (ref($opt) eq 'ARRAY') {
			foreach $item (@$opt) {
				@map = split ' ', $item;
				for ($i = 1; $i<=$#map; $i++) {
					if ($map[$i] eq '#BASENAME#') {
						$pos = index($fn,'.');
						if ($pos > 0) {
							$ret = $map[0] . '=' . substr($fn, 0, $pos);
							last;
						}	else {
							$ret = $map[0] . '=' . $fn;
							last;
						}
					} else {
						$pos = index($fn,$map[$i]);
						if ($pos > 0) {
							$ret = $map[0] . '=' . substr($fn, 0, $pos);
							last;
						}
					}
				}
				last if ($ret ne '');
			}
		} else {
			@map = split ' ', $opt;
			for ($i = 1; $i<=$#map; $i++) {
				if ($map[$i] eq '#BASENAME#') {
					$pos = index($fn,'.');
					if ($pos > 0) {
						$ret = $map[0] . '=' . substr($fn, 0, $pos);
						last;
					}	else {
						$ret = $map[0] . '=' . $fn;
						last;
					}
				} else {
					$pos = index($fn,$map[$i]);
					if ($pos > 0) {
						$ret = $map[0] . '=' . substr($fn, 0, $pos);
						last;
					}
				}
			}
		}
	}
	$ret;
}

sub OverwriteCheck {
	my ($dir) = @_;
	my $ret = 0;
	my $pos = index($dir, '/');
	if ($pos > 0) {
		$dir = substr($dir, 0, $pos);
	}
	if (index($overwrites, "$diffSep$dir$diffSep") >= 0) {
		$ret = 1;
	}
	$ret;
}

sub MergeCheck {
	my ($dir) = @_;
	my $ret = 0;
	my $pos = index($dir, '/');
	if ($pos > 0) {
		$dir = substr($dir, 0, $pos);
	}
	if (index($mergeDirs, "$diffSep$dir$diffSep") >= 0) {
		$ret = 1;
	}
	$ret;
}

sub ProcessFiles {
	my $name = $File::Find::name;
	my ($fileName, $dirs, $suffix);
	# Split the file path into dirs + filename + suffix
	($fileName,$dirs,$suffix) = fileparse($name, qr/\.[^.]*/);
	# Ignore:
	# - files that are not 'regular files'
	# - files with .new and .orig suffixes used by the merge/sort
	# - files with names starting with a '.'
	if (-f $name && $suffix ne '.new' && $suffix ne '.orig' && length($fileName) > 0 && index($fileName, '.') != 0) {
		# Eliminate the 'source folder' portion - we need the relative path
		if (length($main::srcFld) > 0 && index($dirs,$main::srcFld) == 0) {
			$dirs = substr($dirs,length($main::srcFld));
		}
		# Replace '\' with '/' in relative path - so that relative path is
		# shown consistently for Windows/Linux/MacOS
		$dirs =~ s/\\/\//g;
		# Remove the leading '/' from the relative path
		if (index($dirs, '/') == 0) {
			$dirs = substr($dirs,1);
		}
		# Check if the file is one of the 'excluded files' - this check only applies
		# to files at the top folder - examples: package*.xml, distructiveChanges*.xml
		if ($dirs eq '') {
			if (ExcludedFileCheck($fileName)) {
				(print "File $fileName$suffix matched exclude file list\n") if ($main::debug);
			} else {
				my $fRef;
				$fRef->{MERGE_OPTION} = 'merge';
				$fRef->{MD5_DIGEST} = file_md5_hex($name);
				$fRef->{BASENM} = $fileName;
				$fRef->{SUFFIX} = $suffix;
				$fRef->{FOLDER} = $dirs;
				$main::srcFileRef->{$name} = $fRef;
			}
		# Identify files in 'overwrite' folders (examples: Apex classes, LWC etc.)
		# For files in this category: the entire file is updated if there is a change
		} elsif ($dirs ne '' && OverwriteCheck($dirs)) {
			my $fRef;
			$fRef->{MERGE_OPTION} = 'overwrite';
			$fRef->{MD5_DIGEST} = file_md5_hex($name);
			$fRef->{BASENM} = $fileName;
			$fRef->{SUFFIX} = $suffix;
			$fRef->{FOLDER} = $dirs;
			$fRef->{METADATA} = GetMetadataInfo($dirs, "$fileName$suffix");
			$main::srcFileRef->{$name} = $fRef;
		# Identify files in 'merge' folders (examples: objects)
		# For files in this category: metadata is parsed and updated at the detail level
		} elsif ($dirs ne '' && MergeCheck($dirs)) {
			my $fRef;
			$fRef->{MERGE_OPTION} = 'merge';
			$fRef->{MD5_DIGEST} = file_md5_hex($name);
			$fRef->{BASENM} = $fileName;
			$fRef->{SUFFIX} = $suffix;
			$fRef->{FOLDER} = $dirs;
			$main::srcFileRef->{$name} = $fRef;
		} else {
			(print "Skipping file $name\n") if ($debug);
		}
	}
}

sub UpdateRptHeader {
	my ($rpt, $fldNm, $fldTag) = @_;
	my $colNm;
	if ($fldTag eq 'SRC') {
		$colNm = 'New Value';
	} elsif ($fldTag eq 'TRG1') {
		$colNm = 'Old Value';
	} else {
		$colNm = $fldTag;
	}
	$hdrRef = $rpt->{'HEADER'}->{ 'DIFFHEADER' };
	push (@$hdrRef, $colNm);
	$rpt->{'HEADER'}->{ 'DIFFHEADER' } = $hdrRef;
	# This is another report header - this one contains folder locations
	$colNm = "$fldTag=$fldNm";
	$hdrRef = $rpt->{'HEADER'}->{ 'DIFFHEADER2' };
	push (@$hdrRef, $colNm);
	$rpt->{'HEADER'}->{ 'DIFFHEADER2' } = $hdrRef;
	$colNm;
}

sub ReadDiffFile {
	my ($rpt) = @_;
	my ($diffRef, $diffFh, $i, $errMsg, $reqTSIdx, $mrgActIdx, $mdIdx, $pathIdx,
		$l1KeyIdx, $l2KeyIdx, $l3KeyIdx, $l4KeyIdx, $newValIdx, $oldValIdx, $pos,
		$wtIdx, $devLogNmIdx, $userStoryIdx, $devlIdx, $fileName, $dirs, $suffix);
	$errMsg = '';
	# Return to the working directory at the moment when the program was started
	chdir($currentWorkingDir);

	my $diffRpt = $rpt->{ 'CURRENT' }->{ 'DIFF_FILE_NAME' };
	my $goodHeader = $rpt->{'HEADER'}->{ 'DIFFHEADER' };
	#[ 'Developer Work Log Name', 'Request Time Stamp',
	#'Work Team', 'Developer Name', 'User Story', 'Merge Action',
	#'Metadata', 'Path', 'L1 Key', 'L2 Key', 'L3 Key', 'L4 Key',
	#'New Value', 'Old Value'
	#];
	my $hdrLen = @$goodHeader;
	# Check if New Value and Old Value columns are defined in the header
	# (these will not be in the header var if the user is restarting merge using
	# the diff file from an earlier file compare...)
	if ($goodHeader->[$hdrLen-1] eq 'L4 Key') {
		push(@$goodHeader, ('New Value', 'Old Value'));
		$hdrLen = @$goodHeader;
	}
	my $csv = Text::CSV->new ({binary => 1, always_quote => 1});
	open $diffFh, "<:encoding(utf8)", "$diffRpt" or die "Can't read the diff file $diffRpt: $!";
	my $header = $csv->getline($diffFh); # Read the header line
	# Capture positions of columns we are interested in...
	# Sanity check of the diff file header: the order of columns does not have to
	# be the same, but all columns must be present, either by label name
	# or by API name
	my $colCnt = 0;
	for ($i=0; $i<$hdrLen; $i++) {
		my $cNm = $goodHeader->[$i];
		if ($cNm eq 'Request Time Stamp' || $cNm eq 'Request_Time_Stamp__c') {
			$reqTSIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'Merge Action' || $cNm eq 'Merge_Action__c') {
			$mrgActIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'Developer Work Log Name' || $cNm eq 'Developer_Work_Log_Name__c') {
			$devLogNmIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'Work Team' || $cNm eq 'Work_Team__c') {
			$wtIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'User Story' || $cNm eq 'User_Story__c') {
			$userStoryIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'Developer Name' || $cNm eq 'Developer_Name__c') {
			$devlIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'Metadata' || $cNm eq 'Metadata__c') {
			$mdIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'Path' || $cNm eq 'Path__c') {
			$pathIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'L1 Key' || $cNm eq 'L1_Key__c') {
			$l1KeyIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'L2 Key' || $cNm eq 'L2_Key__c') {
			$l2KeyIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'L3 Key' || $cNm eq 'L3_Key__c') {
			$l3KeyIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'L4 Key' || $cNm eq 'L4_Key__c') {
			$l4KeyIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'New Value' || $cNm eq 'New_Value__c') {
			$newValIdx = $i;
			$colCnt++;
		} elsif ($cNm eq 'Old Value' || $cNm eq 'Old_Value__c') {
			$oldValIdx = $i;
			$colCnt++;
		}
	}
	if ($colCnt < 14) {
		$errMsg = "The header of the diff file is missing some of the required columns, exiting...\n" .
			"List of columns required (API names instead of labels are allowed e.g. Work_Team__c instead of Work Team):\n" .
			join(',', @$goodHeader);
	}
	if ($errMsg ne '') {
		print "$errMsg";
		exit;
	}
	my ($thisReqTS, $thisPath, $prevReqTS, $prevPath);
	$thisReqTS = $thisPath = $prevReqTS = $prevPath = '';
	my ($mergeAction, $metadata, $mdTp, $mdNm, $l1Key, $l2Key, $l3Key, $l4Key, $lvl);
	my $pckgRef = {};
	my $dstrRef = {};
	$rpt->{DELTA}->{DESTRUCTIVE} = {};
	$rpt->{DELTA}->{PACKAGE} = {};
	while (my $row = $csv->getline($diffFh)) {
		$thisReqTS = $row->[$reqTSIdx];
		$thisPath = $row->[$pathIdx];
		if ($thisPath ne $prevPath || $thisReqTS ne $prevReqTS) {
			$rpt->{MERGE}->{$thisPath}->{$thisReqTS} = [];
		}
		my $arrRef = $rpt->{MERGE}->{$thisPath}->{$thisReqTS};
		my $ref = {};
		$metadata = $row->[$mdIdx];
		$mergeAction = $row->[$mrgActIdx];
		$l1Key = $row->[$l1KeyIdx];
		$l2Key = $row->[$l2KeyIdx];
		$l3Key = $row->[$l3KeyIdx];
		$l4Key = $row->[$l4KeyIdx];
		$ref->{METADATA} = $metadata;
		$ref->{MERGE_ACTION} = $mergeAction;
		$ref->{L1_KEY} = $l1Key;
		$ref->{L2_KEY} = $l2Key;
		$ref->{L3_KEY} = $l3Key;
		$ref->{L4_KEY} = $l4Key;
		if ($l4Key ne '') {
			$lvl = 4;
		} elsif ($l3Key ne '' && $l3Key ne '#CONTENTS#') {
			$lvl = 3;
		} elsif ($l2Key ne '' && $l2Key ne '#CONTENTS#') {
			$lvl = 2;
		} elsif ($l1Key ne '' && $l1Key ne '#OVERWRITE#' && $l1Key ne '#NEW_METADATA#') {
			$lvl = 1;
		} else {
			$lvl = 0; # this is the update of the entire metadata file
		}

		# Parse the file path
		($fileName,$dirs,$suffix) = fileparse($thisPath, qr/\.[^.]*/);
		$dirs =~ s/\\/\//g;
		$pos = index($dirs, '/');
		($dirs = substr($dirs, 0, $pos)) if ($pos > 0);

		# Capture information to generate package.xml and destructiveChanges.xml
		($mdTp, $mdNm) = split(/=/, $metadata, 2);

		if ($lvl == 0 && index('~Delete Item~Delete File~',$mergeAction) > 0) {
			my $delRef = $rpt->{DELTA}->{DESTRUCTIVE}->{$mdTp} // {};
			$delRef->{$mdNm} = $thisPath; # Path needed to find folder with all relevant files
			$rpt->{DELTA}->{DESTRUCTIVE}->{$mdTp} = $delRef;
		} else {
			my $pckRef = $rpt->{DELTA}->{PACKAGE}->{$mdTp} // {};
			my $metadata = $pckRef->{'#METADATA#'} // '~';
			my $paths = $pckRef->{'#PATHS#'} // '~';
			($metadata .= "$mdNm~") if (index($metadata, "~$mdNm~") < 0);
			($paths .= "$thisPath~") if (index($paths, "~$thisPath~") < 0);
			$pckRef->{'#METADATA#'} = $metadata;
			$pckRef->{'#PATHS#'} = $paths;
			$pckRef->{'#FOLDER#'} = $dirs;
			$pckRef->{$mdNm} = $thisPath; # Path needed to find folder with all relevant files
			$rpt->{DELTA}->{PACKAGE}->{$mdTp} = $pckRef;
		}
		# Add a new line after "NEW_VALUE" - if one is missing
		# NOTE: this is needed, because diff CSV file may be manipulated by
		# hand and trailing line breaks (needed in the metadata file) may be missing
		$newVal = $row->[$newValIdx];
		($newVal .= "\n") if (substr($newVal, -1) ne "\n");
		$ref->{NEW_VALUE} = $newVal;
		$ref->{OLD_VALUE} = $row->[$oldValIdx];
		$ref->{DEV_LOG_NM} = $row->[$devLogNmIdx];
		$ref->{WORK_TEAM} = $row->[$wtIdx];
		$ref->{USER_STORY} = $row->[$userStoryIdx];
		$ref->{DEVELOPER} = $row->[$devlIdx];
		push(@$arrRef, $ref);
		$rpt->{MERGE}->{$thisPath}->{$thisReqTS} = $arrRef;
		$prevPath = $thisPath;
		$prevReqTS = $thisReqTS;
	}
	close $diffFh;
}

# Compare files in folders
# NOTE: $srcFldNm is the 'source folder', $fldLstRef point to a list containing source and target folders
#
sub CompareFiles {
	my ($srcFldNm, $fldLstRef, $cfg, $rpt) = @_;
	my ($href, $report, $fNum, $i, $fn, @fNames, $hdrRef, $targetFld, $mTp, $oNm,
		$fldCnt, $relFilePath, $srcMD5, $trgMD5, $rptKey, $srcMetaDt);
	UpdateRptHeader($rpt, $srcFldNm, 'SRC');
	$fldCnt = @$fldLstRef - 1;
	for (my $i=1; $i<=$fldCnt; $i++) {
			UpdateRptHeader($rpt, $fldLstRef->[$i], "TRG$i");
	}
	# Prepare a list of files to merge
	my @dirList = ($srcFldNm);
	find(\&ProcessFiles, @dirList);

	foreach $fn (sort(keys(%$srcFileRef))) {
		$relFilePath = $srcFileRef->{$fn}->{FOLDER} .
			$srcFileRef->{$fn}->{BASENM} . $srcFileRef->{$fn}->{SUFFIX};
		# examine if the file exists in 'target' and, if the file does not exist,
		# set the 'new file' flag

		# examine 'regular' files
		# (ignore temporary files with .new/.orig suffix and hidden files with names starting with a '.')
		if ($srcFileRef->{$fn}->{MERGE_OPTION} eq 'merge') {
			# parse metadata file in the source folder
			$rpt->{ 'CURRENT' }->{ 'FLD_TP_NM' } = "SRC=$srcFldNm";
			$rpt->{ 'CURRENT' }->{ 'FILE_PATH' } = $relFilePath;
			$href = ParseMetadataFile($fn, $cfg, $rpt);
			# now, do the same for all files with matching names in target folders...
			for (my $i=1; $i<=$fldCnt; $i++) {
				$targetFld = $fldLstRef->[$i];
				if (-f "$targetFld/$relFilePath") {
					$rpt->{ 'CURRENT' }->{ 'FLD_TP_NM'} = "TRG$i=$targetFld";
					$href = ParseMetadataFile("$targetFld/$relFilePath", $cfg, $rpt);
				} else {
					# Note that the file does not exist in target - in this case,
					# Merge will copy file from source to target
					$mTp = $href->{METADATA_TYPE};
					$oNm = $href->{METADATA_NAME};
					$srcMD5 = $srcFileRef->{$fn}->{MD5_DIGEST};
					$rptKey = "$relFilePath$diffSep#NEW_METADATA#";
					$rptRef->{$mTp}->{$oNm}->{"SRC=$srcFldNm"}->{$rptKey} = $srcMD5;
				}
			}
		} elsif ($srcFileRef->{$fn}->{MERGE_OPTION} eq 'overwrite') {
			$rpt->{ 'CURRENT' }->{ 'FLD_TP_NM' } = "SRC=$srcFldNm";
			$rpt->{ 'CURRENT' }->{ 'FILE_PATH' } = $relFilePath;
			$srcMD5 = $srcFileRef->{$fn}->{MD5_DIGEST};
			$srcMetaDt = $srcFileRef->{$fn}->{METADATA} // '';
			$rptKey = "$relFilePath$diffSep#OVERWRITE#";
			if ($srcMetaDt ne '') {
				($mTp, $oNm) = split('=',$srcMetaDt,2);
			} else {
				$mTp = $oNm = 'Unknown';
			}
			$rptRef->{$mTp}->{$oNm}->{"SRC=$srcFldNm"}->{$rptKey} = $srcMD5;
			for (my $i=1; $i<=$fldCnt; $i++) {
				$targetFld = $fldLstRef->[$i];
				if (-f "$targetFld/$relFilePath") {
					$trgMD5 = file_md5_hex("$targetFld/$relFilePath");
					$rptRef->{$mTp}->{$oNm}->{"TRG$i=$targetFld"}->{$rptKey} = $trgMD5;
				}
			}
		}
	}
	CreateReportFiles($rpt,$cfg);
	CreateDuplicateKeyReport($rpt, $cfg);
}

sub AddChngLog {
	my ($fileName, $chLogRef, $chng, $msgTp, $msg) = @_;
	my ($itemPath, $fullMsg, $lvl);
	$lvl = $chng->{LEVEL};
	if ($lvl == 4) {
		$itemPath = $chng->{L1_KEY} . '->' . $chng->{L2_KEY}
			. '->' . $chng->{L3_KEY} . '->' . $chng->{L4_KEY};
	} elsif ($lvl == 3) {
		$itemPath = $chng->{L1_KEY} . '->' . $chng->{L2_KEY}
			. '->' . $chng->{L3_KEY};
	} elsif ($lvl == 2) {
		$itemPath = $chng->{L1_KEY} . '->' . $chng->{L2_KEY};
	} elsif ($lvl == 1) {
		$itemPath = $chng->{L1_KEY};
	} else {
		$itemPath = '';
	}
	$fullMsg = 'Action ' . $chng->{MERGE_ACTION} . " $itemPath: $msg";
 	if ($msgTp eq 'Error') {
		if (!defined($chLogRef->{ERRORS}->{$fileName})) {
			$chLogRef->{ERRORS}->{$fileName} = [];
		}
		my $errRef = $chLogRef->{ERRORS}->{$fileName};
		push(@$errRef, $fullMsg);
	} elsif ($msgTp eq 'Warning') {
		if (!defined($chLogRef->{WARNINGS}->{$fileName})) {
			$chLogRef->{WARNINGS}->{$fileName} = [];
		}
		my $warnRef = $chLogRef->{WARNINGS}->{$fileName};
		push(@$warnRef, $fullMsg);
	} elsif ($msgTp eq 'Info') {
		if (!defined($chLogRef->{INFO}->{$fileName})) {
			$chLogRef->{INFO}->{$fileName} = [];
		}
		my $infoRef = $chLogRef->{INFO}->{$fileName};
		push(@$infoRef, $fullMsg);
	}
}

# Merge files in the target folder from files in the source folder and the diff file
# NOTE: $srcFldNm is the 'source folder', $trgFldNm is the target folder
#
sub MergeFiles {
	my ($srcFldNm, $trgFldNm, $cfg, $rpt) = @_;
	my ($href, $fn, $mTp, $oNm, $srcPath, $trgPath, $newValue, $oldValue, $chngLogRef,
		$srcMD5, $trgMD5, $mergeAction, $metaData, $l1Key, $l2Key, $l3Key, $l4Key,
		$devLogNm, $wt, $uStory, $devl, $lvl, $updFilesRef, $itemChngRef, $itemKey,
		$fileName,$dirs,$suffix);

	# Re-read the diff file
 	ReadDiffFile($rpt);
	my $mergeFileRef = $rpt->{MERGE};

	# Merge works as follows:
	# 1) Loop through a list of all files in the diff file (sorted)
	# 2) For each file loop through change request timestamps low to high (indicating different PRs)
	# 3) Apply changes on a single file in target folder as indicated in the PR
	# 4) Capture a report of changes that have been applied and any warnings regarding the outcome
	foreach $fn (sort(keys(%$mergeFileRef))) {
		my $fileRef = $mergeFileRef->{$fn};
		$srcPath = "$srcFldNm\/$fn";
		$trgPath = "$trgFldNm\/$fn";
		foreach $ts (sort(keys(%$fileRef))) {
			my $changes = $fileRef->{$ts};
			$itemChngRef = {};
			$itemChanges = 0;
			foreach $chng (@$changes) {
				$mergeAction = $chng->{MERGE_ACTION};
				$metaData = $chng->{METADATA};
				$l1Key = $chng->{L1_KEY};
				$l2Key = $chng->{L2_KEY};
				$l3Key = $chng->{L3_KEY};
				$l4Key = $chng->{L4_KEY};
				$l1SName = $l1Val = $l2SName = $l2Val = $l3SName = $l3Val = $l4SName = $l4Val = '';
				if ($l4Key ne '') {
					$lvl = 4;
					($l4SName = $l4Val = $l4Key) if (index($l4Key, '=') < 0);
				} elsif ($l3Key ne '' && $l3Key ne '#CONTENTS#') {
					$lvl = 3;
					($l3SName = $l3Val = $l3Key) if (index($l3Key, '=') < 0);
				} elsif ($l2Key ne '' && $l2Key ne '#CONTENTS#') {
					$lvl = 2;
					($l2SName = $l2Val = $l2Key) if (index($l2Key, '=') < 0);
				} elsif ($l1Key ne '' && $l1Key ne '#OVERWRITE#' && $l1Key ne '#NEW_METADATA#') {
					$lvl = 1;
				} else {
					$lvl = 0; # this is the update of the entire metadata file
				}
				$chng->{LEVEL} = $lvl;
				if ($lvl > 0 && index($l1Key, '=') > 0) {
					($l1SName, $l1Val) = split('=', $l1Key, 2);
				}
				if ($lvl > 1 && index($l2Key, '=') > 0) {
					($l2SName, $l2Val) = split('=', $l2Key, 2);
				}
				if ($lvl > 2 && index($l3Key, '=') > 0) {
					($l3SName, $l3Val) = split('=', $l3Key, 2);
				}
				if ($lvl > 3 && index($l4Key, '=') > 0) {
					($l4SName, $l4Val) = split('=', $l4Key, 2);
				}
				$newValue = $chng->{NEW_VALUE};
				$oldValue = $chng->{OLD_VALUE};
				$devLogNm = $chng->{DEV_LOG_NM};
				$wt = $chng->{WORK_TEAM};
				$uStory = $chng->{USER_STORY};
				$devl = $chng->{DEVELOPER};
				if (index('~Create File~Update File~',$mergeAction) > 0) {
					if (-f $srcPath) {
						if (defined($updFilesRef->{$fn})) {
							AddChngLog($fn, $chngLogRef, $chng, 'Info', "Ignored, file $$trgPath already updated to the latest version");
						} else {
							# Split the target file path into dirs + filename + suffix
							($fileName,$dirs,$suffix) = fileparse($trgPath, qr/\.[^.]*/);
							# Create the target folder, if it does not exist yet
							make_path($dirs) if (!-d $dirs);
							# Copy file to the target folder
							copy($srcPath, $trgPath);
							$updFilesRef->{$fn} = 1;
							AddChngLog($fn, $chngLogRef, $chng, 'Info', "File $$trgPath updated from $srcPath");
						}
					} else {
						AddChngLog($fn, $chngLogRef, $chng, 'Error', "File $srcPath cannot be copied to $trgPath because it does not exist");
					}
				} elsif ($mergeAction eq 'Delete File') {
					if (-f $trgPath) {
						unlink($trgPath);
						AddChngLog($fn, $chngLogRef, $chng, 'Info', "File $$trgPath has been deleted");
					} else {
						AddChngLog($fn, $chngLogRef, $chng, 'Warning', "File $trgPath does not exist");
					}
				} elsif (index('~Create Item~Update Item~Delete Item~',$mergeAction) > 0) {
					if (defined($updFilesRef->{$fn})) {
						AddChngLog($fn, $chngLogRef, $chng, 'Warning', "Action ignored because file $$trgPath already updated to the latest version");
					} else {
						if ($mergeAction eq 'Create Item') {
							my ($newItems, $item);
							if ($lvl == 1) {
								$newItems = $itemChngRef->{$l1SName}->{'##CREATE##'} // [];
								$item->{SORT_KEY} = $l1Val;
								$item->{CONTENT} = $chng->{NEW_VALUE};
								push(@$newItems, $item);
								$itemChngRef->{$l1SName}->{'##CREATE##'} = $newItems;
							} elsif ($lvl == 2) {
								$newItems = $itemChngRef->{$l1SName}->{$l1Val}->{$l2SName}->{'##CREATE##'} // [];
								$item->{SORT_KEY} = $l2Val;
								$item->{CONTENT} = $chng->{NEW_VALUE};
								push(@$newItems, $item);
								$itemChngRef->{$l1SName}->{$l1Val}->{$l2SName}->{'##CREATE##'} = $newItems;
							} elsif ($lvl == 3) {
								$newItems = $itemChngRef->{$l1SName}->{$l1Val}->{$l2SName}->{$l2Val}->{$l3SName}->{'##CREATE##'} // [];
								$item->{SORT_KEY} = $l3Val;
								$item->{CONTENT} = $chng->{NEW_VALUE};
								push(@$newItems, $item);
								$itemChngRef->{$l1SName}->{$l1Val}->{$l2SName}->{$l2Val}->{$l3SName}->{'##CREATE##'} = $newItems;
							} elsif ($lvl == 4) {
								$newItems = $itemChngRef->{$l1SName}->{$l1Val}->{$l2SName}->{$l2Val}->{$l3SName}->{$l3Val}->{$l4SName}->{'##CREATE##'} // [];
								$item->{SORT_KEY} = $l4Val;
								$item->{CONTENT} = $chng->{NEW_VALUE};
								push(@$newItems, $item);
								$itemChngRef->{$l1SName}->{$l1Val}->{$l2SName}->{$l2Val}->{$l3SName}->{$l3Val}->{$l4SName}->{'##CREATE##'} = $newItems;
							}
						} else {
							my ($action,$item2);
							$action = ($mergeAction eq 'Update Item')?'##CHANGE##':'##DELETE##';
							if ($lvl == 1) {
								$itemChngRef->{$l1SName}->{$l1Val}->{$action} = $chng->{NEW_VALUE};
							} elsif ($lvl == 2) {
								$itemChngRef->{$l1SName}->{$l1Val}->{$l2SName}->{$l2Val}->{$action} = $chng->{NEW_VALUE};
							} elsif ($lvl == 3) {
								$itemChngRef->{$l1SName}->{$l1Val}->{$l2SName}->{$l2Val}->{$l3SName}->{$l3Val}->{$action} = $chng->{NEW_VALUE};
							} elsif ($lvl == 4) {
								$itemChngRef->{$l1SName}->{$l1Val}->{$l2SName}->{$l2Val}->{$l3SName}->{$l3Val}->{$l4SName}->{$l4Val}->{$action} = $chng->{NEW_VALUE};
							}
						}
						$itemChanges++;
					}
				} else {
					AddChngLog($fn, $chngLogRef, $chng, 'Error', "Do not understand this merge action, review diff file");
				}
			}
			if ($itemChanges > 0) {
				$rpt->{ 'CURRENT' }->{ 'MERGE_ACTIONS' } = $itemChngRef;

				# Parse the target file and execute item changes
				$rpt->{ 'CURRENT' }->{ 'FILE_PATH' } = $fn;
				$href = ParseMetadataFile($trgPath, $cfg, $rpt);

				# Reconstruct metadata file
				ReconstructMetaDataFile($trgPath, $href, $cfg);

				# Create a deployment log - TBD
			}
		}
	}
}

# Prepare the delta deployment package
#
sub PrepDeltaPackage {
	my ($trgFldNm, $cfg, $rpt) = @_;
	my ($href, $fn, $mTp, $oNm, $srcPath, $trgPath, $newValue, $oldValue, $chngLogRef,
		$srcMD5, $trgMD5, $mergeAction, $metaData, $l1Key, $l2Key, $l3Key, $l4Key,
		$devLogNm, $wt, $uStory, $devl, $lvl, $updFilesRef, $itemChngRef, $itemKey);

	# Re-read the diff file, if ReadDiffFile has not been exectuted already
	# (during merge phase)
	if (!defined($rpt->{DELTA})) {
		ReadDiffFile($rpt);
	}

	# Get current GMT and prepare diff file name
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = gmtime(time);
	my $zuluTimeFN = sprintf("%04d%02d%02d_%02d%02d%02d",
		$year+1900, $mon+1, $mday, $hour, $min, $sec);


	my $packageRef = $rpt->{DELTA}->{PACKAGE};
	my $destructiveRef = $rpt->{DELTA}->{DESTRUCTIVE};

	# Create a folder for the delta deployment package
	my $deltaFld = $cfgRef->{''}->{'deltaFolder'} // "SfmergeDeltaPckg";
	if (!-e $deltaFld) {
		mkdir($deltaFld) or die "Can't mkdir $deltaFld: $!";
	}
	chdir $deltaFld;
	my $deplFld = "Delta_$zuluTimeFN";
	mkdir($deplFld);
	chdir($deplFld);

	# Create package.xml file
	my $pckgFn =  'package.xml';
	open (PCKG, ">", $pckgFn) or die "Cannot open $pckgFn: $!";
	print PCKG <<'PckgStart';
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
PckgStart

	foreach my $mdTp (sort(keys(%$packageRef))) {
		my $ref = $packageRef->{$mdTp};
		print PCKG <<'PckgTypesStart';
	<types>
PckgTypesStart
		foreach my $mdNm (sort(keys(%$ref))) {
			next if ($mdNm eq '#FOLDER#' || $mdNm eq '#METADATA#' || $mdNm eq '#PATHS#');
			print PCKG <<"PckgMembers";
		<members>$mdNm</members>
PckgMembers
		}
		print PCKG <<"PckgTypesEnd";
		<name>$mdTp</name>
	</types>
PckgTypesEnd
	}

	print PCKG <<"PckgEnd";
	<version>$pckgGenVersion</version>
</Package>
PckgEnd
	close(PCKG);

	# Create destructiveChanges.xml (if any destructive changes are present)
	if (scalar(keys(%$destructiveRef)) > 0) {
		my $dstrFn =  'destructiveChanges.xml';
		open (DSTR, ">", $dstrFn) or die "Cannot open $dstrFn: $!";
		print DSTR <<'DstrStart';
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
DstrStart

		foreach my $mdTp (sort(keys(%$destructiveRef))) {
			my $ref = $packageRef->{$mdTp};
			print DSTR <<'DstrTypesStart';
	<types>
DstrTypesStart
			foreach my $mdNm (sort(keys(%$ref))) {
				print DSTR <<"DstrMembers";
		<members>$mdNm</members>
DstrMembers
			}
			print DSTR <<"DstrTypesEnd";
		<name>$mdTp</name>
	</types>
DstrTypesEnd
		}

		print DSTR <<"DstrEnd";
	<version>$pckgGenVersion</version>
</Package>
DstrEnd
		close(DSTR);
	}

	# Copy metadata files to the package folder
	my ($dir, $metadata, $paths, $fileName, $dirPath, $suffix);
	foreach my $mdTp (sort(keys(%$packageRef))) {
		my $ref = $packageRef->{$mdTp};

		$dir = $packageRef->{$mdTp}->{'#FOLDER#'} // '';
		$metadata = $packageRef->{$mdTp}->{'#METADATA#'} // '';
		$paths = $packageRef->{$mdTp}->{'#PATHS#'} // '';
		if ($dir ne '' && $metadata ne '' && $paths ne '') {
			# Prepare a list of files in the source folder, where metadata is stored
			my @dirList = ("$trgFldNm/$dir");
			$srcFileRef = {}; # Reinitialize global val used in find below...
			find(\&ProcessFiles, @dirList);
			foreach my $fn (sort(keys(%$srcFileRef))) {
				my $relFilePath = $srcFileRef->{$fn}->{FOLDER} .
					$srcFileRef->{$fn}->{BASENM} . $srcFileRef->{$fn}->{SUFFIX};
				if ($srcFileRef->{$fn}->{MERGE_OPTION} eq 'merge') {
					# For files that are merged - copy the file to delta package
					if (index($paths,"~$relFilePath~") >= 0) {
						($fileName,$dirPath,$suffix) = fileparse($relFilePath, qr/\.[^.]*/);
						make_path($dirPath) if (!-d $dirPath);
						copy($fn, $relFilePath);
					}
				} elsif ($srcFileRef->{$fn}->{MERGE_OPTION} eq 'overwrite') {
					my $srcMetaDt = $srcFileRef->{$fn}->{METADATA} // '';
					my ($thisMTp, $thisONm);
					if ($srcMetaDt ne '') {
						($thisMTp, $thisONm) = split('=',$srcMetaDt,2);
					}
					# For files that are overwritten - copy files if the $metadata
					# name inferred from the file name matches
					# NOTE: this is needed because several files may be needed e.g.
					# for ApexClass - the file containing code and .xml file for the class
					if ($thisONm ne '' && index($metadata, "~$thisONm~")) {
						($fileName,$dirPath,$suffix) = fileparse($relFilePath, qr/\.[^.]*/);
						make_path($dirPath) if (!-d $dirPath);
						copy($fn, $relFilePath);
					}
				}
			}
		}
	}
}

# Sort metadata files in folder and delete unnecessary contents
# (config contains instructions for sorting and stripping)
# Input: folder path and config reference
# Output: no output
sub SortFiles {
	my ($fldNm, $cfg, $rpt) = @_;
	my ($href, $report, $fNum, $i, $fn, @fNames, $hdrRef);
	$rpt->{ 'CURRENT' }->{ 'FLD_TP_NM'} = UpdateRptHeader($rpt, $fldNm, 'SRC');
	opendir(SRC, $fldNm) or die "Can't open directory $fldNm: $!";
	while (defined($fn = readdir(SRC))) {
		# examine 'regular' files
		# (ignore temporary files with .new/.orig suffix and hidden files with names starting with a '.')
		if (-f "$fldNm/$fn" && $fn !~ /^\./ && $fn !~ /\.new$/ && $fn !~ /\.orig$/) {
			push (@fNames, "$fldNm/$fn");
		}
	}
	my $rptFn =  'MergeReport.txt';
	open (RPT, ">", $rptFn) or die "Cannot open $rptFn: $!";
	foreach $fn (@fNames) {
		# parse metadata file
		$rpt->{ 'CURRENT' }->{ 'FILE_PATH' } = $fn;
		$href = ParseMetadataFile($fn, $cfg, $rpt);
		$fNum = sprintf("F%5.5d", $i++);
		if ($cfgRef->{''}->{ 'reportMode' }) {
			CreateReportFiles($rpt, $cfg);
		}

		if (defined($href->{ERROR_MESSAGE})) {
			$report->{$fNum} = $href;
		} elsif (!$cfgRef->{''}->{ 'reportMode' }) {
			# Reconstruct metadata file
			ReconstructMetaDataFile($fn, $href, $cfg);
		}
	}
	closedir(SRC);
	close(RPT);
}

sub CheckFilters {
	my ($fOpt, $oName) = @_;
	my $fRef = [];
	my ($oNm, $sNm);
	if (ref($fOpt) eq 'ARRAY') {
		foreach my $opt (@$fOpt) {
			($oNm, $sNm) = split(/\./, $opt, 2);
			if ( $oName eq $oNm ) {
				push(@$fRef, $sNm);
			}
		}
	} else {
		($oNm, $sNm) = split(/\./, $fOpt, 2);
		if ( $oName eq $oNm ) {
			push(@$fRef, $sNm);
		}
	}
	return $fRef;
}

sub CheckFiltersPresent {
	my ($fOpt, $oName) = @_;
	my $ret = 0;
	if (ref($fOpt) eq 'ARRAY') {
		foreach my $opt (@$fOpt) {
			if ( $oName eq $opt ) {
				$ret = 1;
			}
		}
	} else {
		if ( $oName eq $fOpt ) {
			$ret = 1;
		}
	}
	return $ret;
}

sub CheckSubFiltersPresent {
	my ($cfgRef, $mdTp, $sName, $oName) = @_;
	my $ret = 0;
	my ($fOpt);
	foreach my $item (keys(%$cfgRef)) {
		next if ($item !~ /^$mdTp-$sName-.*$/ || !defined($cfgRef->{$item}->{'filter'}));
		$fOpt = $cfgRef->{$item}->{'filter'};
		if (ref($fOpt) eq 'ARRAY') {
			foreach my $opt (@$fOpt) {
				if ( $opt =~ /^$oName\./) {
					$ret = 1;
					last;
				}
			}
		} else {
			if ( $fOpt =~ /^$oName\./ ) {
				$ret = 1;
			}
		}
		last if ($ret);
	}
	return $ret;
}

sub FilterMatched {
	my ($key, $filterRef) = @_;
	foreach my $opt (@$filterRef) {
		if ($opt eq $key) {
			return 1;
		}
	}
	return 0;
}

sub AddSection {
	my ($href, $sType, $sName, $sNum, $cfgRef, $rptRef) = @_;
	my $sectionNumber = sprintf("S%5.5d", $sNum);
	my $sectionRef;
	my ($mType, $oName, $sortOpt, $reconstructOpt, $stripOpt, $filterOpt);
	$mType = $href->{ 'METADATA_TYPE' };
	$oName = $href->{ 'METADATA_NAME' };
	$href->{ 'CURRENT_SECTION_NAME' } = ($sType eq 'Params')?'PARAMS':$sName;
	$sectionRef->{ 'SECTION_TYPE' } = $sType;
	$sectionRef->{ 'SECTION_NAME' } = $sName;
	(print "Added section #$sNum $sName, type $sType, metadata type: $mType\n") if ($debug);
	if ($sType eq 'Standard') {
		($sortOpt = $cfgRef->{"$mType-$sName"}->{'sort'}) if (defined($cfgRef->{"$mType-$sName"}->{'sort'}));
		($sortOpt = $cfgRef->{$mType}->{'sort'}) if (!defined($sortOpt) && defined($cfgRef->{$mType}->{'sort'}));
		($sortOpt = $cfgRef->{''}->{'sort'}) if (!defined($sortOpt));
		$reconstructOpt = $cfgRef->{"$mType-$sName"}->{'reconstruct'} // "#SORT#";
		if (defined($cfgRef->{"$mType-$sName"}->{'filter'})) {
			$filterOpt = CheckFilters($cfgRef->{"$mType-$sName"}->{'filter'}, $oName);
		} else {
			$filterOpt = [];
		}
		($stripOpt = $cfgRef->{"$mType-$sName"}->{'delete'}) if (defined($cfgRef->{"$mType-$sName"}->{'delete'}));
		($stripOpt = $cfgRef->{$mType}->{'delete'}) if (!defined($stripOpt) && defined($cfgRef->{$mType}->{'delete'}));
		$sectionRef->{ 'SORT' } = $sortOpt;
		$sectionRef->{ 'DELETE' } = $stripOpt;
		$sectionRef->{ 'FILTER' } = $filterOpt;
		$sectionRef->{ 'RECONSTRUCT' } = $reconstructOpt;
	}
	$sectionRef->{ 'SUB_SECTIONS' } = [];
	$href->{ 'SECTIONS' }->{ $sectionNumber } = $sectionRef;
}

sub GetSortKey {
	my ($sSec, $sOpt) = @_;
	my ($pos, $endPos, $key, $stp, $lvl, $sCopy);
	# First - check if this is a simple section containing just parameters,
	# or a complex section - containing sub sections
	my @lines = split /^/, $sSec;
	shift(@lines) if ($#lines > 0 && $lines[0] =~ /^\s*<\w+>\s*$/); # remove line #1 if it contains a section beginning line
	pop(@lines) if ($lines[-1] =~ /^\s*<\/\w+>\s*$/); # remove the last line if it contains the section end line
	$sCopy = $sSec;
	$sSec = $key = '';
	$stp = 'SIMPLE'; # presume it is a simple section
	$lvl = 0;
	foreach (@lines) {
		if (/^\s*<\w+>\s*$/) {
			$stp = 'COMPLEX';
			$lvl++;
		} elsif (/^\s*<\/\w+>\s*$/) {
			$lvl--;
		} elsif ($lvl == 0) {
			$sSec .= $_;
		}
	}
	if (ref($sOpt) eq 'ARRAY') {
		foreach my $opt (@$sOpt) {
			$pos = index($sSec, $opt);
			if ( $pos > -1) {
				$pos += length($opt);
				$endPos = index($sSec, '<', $pos);
				$key = substr($sSec, $pos, $endPos - $pos);
				last;
			}
		}
	} elsif ($sOpt eq '#SINGLE#') {
		# the key for 'singleton' sections in SF metadata is a string #SINGLE#
		$key = $sOpt;
	} elsif ($sOpt eq '#CONTENT#') {
		# The key for #CONTENT# is the MD5 digest of the entire section content
		$sSec = $sCopy;
	} else {
		$pos = index($sSec, $sOpt);
		if ( $pos > -1) {
			$pos += length($sOpt);
			$endPos = index($sSec, '<', $pos);
			$key = substr($sSec, $pos, $endPos - $pos);
		}
	}

	# Fallback: sort key is MD5 digest of the entire sub-section content in hex
	# (but without leading spaces and open/close tags)
	if ($key eq '') {
		chomp($sSec);
		($key = $sSec) =~ s/^\s+//gm; # remove leading spaces before calculating MD5 digest
		$key =~ s/\R//gm; # remove line breaks too...
		$key = md5_hex($key);
	}
	return ($key, $stp);
}

sub GetParamKey {
	my ($param) = @_;
	my ($key);
	($key = $param) =~ s/^\s*<(\w+)>[^<>]+<\/\w+>\s*$/$1/;
	$key;
}

sub StripSubSection {
	my ($sSec, $stOpt) = @_;
	my $delFlg = 0;
	if (ref($stOpt) eq 'ARRAY') {
		foreach my $opt (@$stOpt) {
			$delFlg = 1;
			if ( index($sSec, $opt) < 0 ) {
				return 0;
			}
		}
	} else {
		if ( index($sSec, $stOpt) >= 0 ) {
			return 1;
		}
	}
	return $delFlg;
}

sub DuplicateKeyCheck {
	my ($href,$mType,$oName,$fldTpNm,$rptKey,$val) = @_;
	my $fullKey = "$mType=$oName$diffSep$fldTpNm$diffSep$rptKey";
	my $dupRef = $href->{ 'DUPLICATE_KEY_CHECK' }->{ $fullKey };
	if (!defined($dupRef)) {
		$dupRef = {};
		$dupRef->{COUNT} = 1;
		$dupRef->{VALUE} = $val;
	} else {
		$dupRef->{COUNT}++
	}
	$href->{ 'DUPLICATE_KEY_CHECK' }->{ $fullKey } = $dupRef;
}

sub CaptureDuplicateKeys {
	my ($href, $rptref) = @_;
	my $dupKeyCheckRef = $href->{'DUPLICATE_KEY_CHECK'};
	foreach my $item (sort(keys(%$dupKeyCheckRef))) {
		next if ($href->{ 'DUPLICATE_KEY_CHECK' }->{ $item }->{COUNT} == 1);
		$rptref->{ 'DUPLICATE' }->{ $item } = $href->{ 'DUPLICATE_KEY_CHECK' }->{ $item };
	}
}

sub AddSubSection {
	my ($href, $sNum, $sName, $subSection, $cfgRef, $rptRef) = @_;
	my $sectionNumber = sprintf("S%5.5d", $sNum);
	my $subRef = $href->{ 'SECTIONS' }->{ $sectionNumber }->{ 'SUB_SECTIONS' };
	my $sectionType = $href->{ 'SECTIONS' }->{ $sectionNumber }->{ 'SECTION_TYPE' };
	my $filtersPresent = $href->{ 'FILTERS_PRESENT' };
	my $mType = $href->{ 'METADATA_TYPE' };
	my $oName = $href->{ 'METADATA_NAME' };
	my $fldTpNm = $rptRef->{ 'CURRENT' }->{ 'FLD_TP_NM' };
	my $filePath = $rptRef->{ 'CURRENT' }->{ 'FILE_PATH' };
	my $reportFlg = $cfgRef->{''}->{ 'reportMode' };
	my $mergeActions = $rptRef->{ 'CURRENT' }->{ 'MERGE_ACTIONS' };
	my $mergeCheck = (defined($mergeActions) && $mType ne $sName && scalar(keys(%$mergeActions)) > 0)?1:0;
	my $parserFlg = '';
	($parserFlg = $cfgRef->{"$mType-$sName"}->{'parser'}) if (defined($cfgRef->{"$mType-$sName"}->{'parser'}));
	my $subSectionRef;
	# Sort and Delete options are only for Standard sections
	my $del = 0;
	my $subFiltersPresent = 0;
	if (($sectionType eq 'Standard')) {
		my $sort = $href->{ 'SECTIONS' }->{ $sectionNumber }->{ 'SORT' };
		my $strip = $href->{ 'SECTIONS' }->{ $sectionNumber }->{ 'DELETE' };
		my $filter = $href->{ 'SECTIONS' }->{ $sectionNumber }->{ 'FILTER' };
		($del = StripSubSection($subSection, $strip)) if (defined($strip));
		if (!$del) {
			my ($sortKey, $sTp) = GetSortKey($subSection, $sort);
			if (!$filtersPresent || $reportFlg || $mergeCheck || FilterMatched($sortKey, $filter)) {
				$subSectionRef->{ 'SORT_KEY' } = $sortKey;
				$href->{ 'CURRENT_SECTION_KEY' } = $sortKey;
				if ($mergeCheck && defined($mergeActions->{$sName}->{$sortKey}->{'##CHANGE##'})) {
					$subSection = $mergeActions->{$sName}->{$sortKey}->{'##CHANGE##'};
				} elsif ($mergeCheck && defined($mergeActions->{$sName}->{$sortKey}->{'##DELETE##'})) {
					$del = 1;
				} elsif ($sTp eq 'COMPLEX' && $parserFlg ne '#FULLSECTION#') {
					$subFiltersPresent = CheckSubFiltersPresent($cfgRef,$mType,$sName,$oName);
					if ($reportFlg || $subFiltersPresent || ($mergeCheck && defined($mergeActions->{$sName}->{$sortKey}))) {
						# Calling a parser for a Sub-Section in case of: reporting, filtering of metadata, code merge
						$subSection = ParseSubSection($href,$oName,$mType,$sName,$cfgRef,$subSection,$rptRef,$subFiltersPresent);
					}
				} else {
					my $rptKey = "$filePath$diffSep$sName=$sortKey";
					my $params = $rptRef->{$mType}->{$oName}->{$fldTpNm}->{$rptKey} // '';
					$params .= $subSection;
					$rptRef->{$mType}->{$oName}->{$fldTpNm}->{$rptKey} = $params;
					DuplicateKeyCheck($href, $mType, $oName, $fldTpNm, $rptKey, $subSection);
				}
				if (!$del) {
					$subSectionRef->{ 'CONTENT' } = $subSection;
					push(@$subRef, $subSectionRef);
				}
				if ($filtersPresent) {
					$href->{ 'MATCHED_FILTERS' }->{$sName} .= "\n$sortKey";
				}
			} else {
				(print "Filtering out sub-section\n$subSection\n" ) if ($debug);
			}

		} else {
			(print "Skipping sub-section\n$subSection\n" ) if ($debug);
		}
	} elsif ($sectionType eq 'Empty') {
		if ($reportFlg) {
			my $rptKey = "$filePath$diffSep$sName=#SINGLE#";
			$rptRef->{$mType}->{$oName}->{$fldTpNm}->{$rptKey} = $subSection;
			DuplicateKeyCheck($href, $mType, $oName, $fldTpNm, $rptKey, $subSection);
		}
		if ($mergeCheck && defined($mergeActions->{$sName}->{'#SINGLE#'}->{'##CHANGE##'})) {
			$subSection = $mergeActions->{$sName}->{'#SINGLE#'}->{'##CHANGE##'};
		} elsif ($mergeCheck && defined($mergeActions->{$sName}->{'#SINGLE#'}->{'##DELETE##'})) {
			$del = 1;
		}
		if (!$filtersPresent && !$del) {
			$subSectionRef->{ 'SORT_KEY' } = '#SINGLE#';
			$subSectionRef->{ 'CONTENT' } = $subSection;
			push(@$subRef, $subSectionRef);
		}
	} else {
		if (!$filtersPresent || $sectionType ne 'Params') {
			if ($mergeCheck && defined($mergeActions->{$sName}->{'#PARAM#'}->{'##CHANGE##'})) {
				$subSection = $mergeActions->{$sName}->{'#PARAM#'}->{'##CHANGE##'};
			} elsif ($mergeCheck && defined($mergeActions->{$sName}->{'#PARAM#'}->{'##DELETE##'})) {
				$del = 1;
			}
			if (!$del) {
				$subSectionRef->{ 'SORT_KEY' } = '#PARAM#';
				$subSectionRef->{ 'CONTENT' } = $subSection;
				push(@$subRef, $subSectionRef);
			}
		}
	}
	if ($mergeCheck) {
		my $addSectionsRef = CheckForNewSections($sName, $mergeActions, $rptRef, 1);
		if (@$addSectionsRef > 0) {
			push(@$subRef, @$addSectionsRef);
		}
	}
}

sub SortSSS {
	my ($mdType,$sName,$cfgRef,$ssName,$sss) = @_;
	my $sortOpt = $cfgRef->{"$mdType-$sName-$ssName"}->{'sort'}
		// $cfgRef->{$mdType}->{'sort'}
		// $cfgRef->{''}->{'sort'};
	my ($sortKey, $sTp) = GetSortKey($sss, $sortOpt);
	($sortKey,$sTp);
}

sub FilterSSS {
	my ($href,$oNm,$mdType,$sName,$cfgRef,$ssName,$ssKey,$sss) = @_;
	my $filterOpt = $cfgRef->{"$mdType-$sName-$ssName"}->{'filter'};
  my $ret = '';
	my $filters = CheckFilters($filterOpt, $oNm);
	if (FilterMatched($ssKey, $filters)) {
		$href->{'SSFilters'}->{"$mdType-$sName"} .= "~$ssName~";
		$ret = $sss;
	}
	$ret;
}

sub SortSSSS {
	my ($mdType,$sName,$cfgRef,$ssName,$sssName,$ssss) = @_;
	my $sortOpt = $cfgRef->{"$mdType-$sName-$ssName-$sssName"}->{'sort'}
		// $cfgRef->{$mdType}->{'sort'}
		// $cfgRef->{''}->{'sort'};
	my ($sortKey, $sTp) = GetSortKey($ssss, $sortOpt);
	($sortKey,$sTp);
}

sub SortSSSSS {
	my ($mdType,$sName,$cfgRef,$ssName,$sssName,$ssssName,$sssss) = @_;
	my $sortOpt = $cfgRef->{"$mdType-$sName-$ssName-$sssName-$ssssName"}->{'sort'}
		// $cfgRef->{$mdType}->{'sort'}
		// $cfgRef->{''}->{'sort'};
	my ($sortKey, $sTp) = GetSortKey($sssss, $sortOpt);
	($sortKey,$sTp);
}

sub ParseSubSection {
	my ($href,$oNm,$mdTp,$sNm,$cfg,$content,$rRef,$subFiltFlg) = @_;
	my @lines = split /^/, $content;
	my ($state, $sKey, $nextState, $ssNm, $sssNm, $ssssNm, $result, $token,
		$sssContent, $ssssContent, $sssssContent,
		$sssStart, $ssssStart, $sssssStart,
		$allSSParams, $allSSSParams, $allSSSSParams,
		$ssKey, $ssTp, $sssKey, $sssTp, $ssssKey, $ssssTp,
		$rptKey, $params, $ret, $fldTpNm, $filePath, $mergeActions, $mergeCheck,
		$mergeSSParams, $mergeSSSParams, $mergeSSSSParams);
	$state = 'StartSubSection';
	$nextState = $result = $token = $sssContent = $ssNm = $sssNm = $ssssNm = '';
	$allSSParams = $allSSSParams = $allSSSSParams = $ssKey = $sssKey = $ssssKey = '';
	$fldTpNm = $rRef->{ 'CURRENT' }->{ 'FLD_TP_NM' };
	$filePath = $rRef->{ 'CURRENT' }->{ 'FILE_PATH' };
	$sKey = $href->{ 'CURRENT_SECTION_KEY' };
	$mergeActions = $rptRef->{ 'CURRENT' }->{ 'MERGE_ACTIONS' }->{$sNm}->{$sKey};
	$mergeCheck = (defined($mergeActions) && scalar(keys(%$mergeActions)) > 0)?1:0;
	$mergeSSParams = ($mergeCheck && defined($mergeActions->{'#PARAMS#'}->{'#PARAMS#'}->{'##CHANGE##'}))?1:0;
	# Add the entire sub-section content to the report struct
	# This will be used if the target file does not contain the sub-section at all.
	$rptKey = "$filePath$diffSep$sNm=$sKey$diffSep#CONTENTS#";
	$rRef->{$mdTp}->{$oNm}->{$fldTpNm}->{$rptKey} = $content;
	foreach (@lines) {
		if ($state eq 'StartSubSection') {
			if (/^\s*<(\w+)>\s*$/) {
				$token = $1;
				if ($token eq $sNm) {
					$result .= $_;
					$nextState = 'ProcessingSSParams';
					if ($mergeSSParams) {
						$allSSParams = $mergeActions->{'#PARAMS#'}->{'#PARAMS#'}->{'##CHANGE##'};
						$result .= $allSSParams;
					}
				} else {
					$nextState = 'Error';
				}
			}
		} elsif ($state eq 'ProcessingSSParams') {
			if (index($_,"</$sNm>") >= 0) {
				$result .= $_;
				$rptKey = "$filePath$diffSep$sNm=$sKey$diffSep#PARAMS#";
				$params = $rRef->{$mdTp}->{$oNm}->{$fldTpNm}->{$rptKey} // '';
				$params .= $allSSParams;
				$rRef->{$mdTp}->{$oNm}->{$fldTpNm}->{$rptKey} = $params;
			} elsif (/^\s*<(\w+)>[^<>]+<\/(\w+)>\s*$/) {
				if (!$mergeSSParams) {
					$result .= $_;
					$allSSParams .= $_;
				}
				$nextState = 'ProcessingSSParams';
			} elsif (/^\s*<(\w+)>\s*$/) {
				$ssNm = $1;
				$sssStart = $_;
				$sssContent = $allSSSParams = $ret = '';
				$nextState = 'ProcessingSSS';
			} else {
				$nextState = 'Error';
			}
		} elsif ($state eq 'ProcessingSSS') {
			if (index($_,"</$ssNm>") >= 0) {
				if ($ssKey eq '') {
					($ssKey, $ssTp) = SortSSS($mdTp,$sNm,$cfg,$ssNm,$sssStart . $allSSSParams);
				}
				$mergeSSSParams = ($mergeCheck && defined($mergeActions->{$ssNm}->{$ssKey}->{'#PARAMS#'}->{'#PARAMS#'}->{'##CHANGE##'}))?1:0;
				if ($mergeSSSParams) {
					$allSSSParams = $mergeActions->{$ssNm}->{$ssKey}->{'#PARAMS#'}->{'#PARAMS#'}->{'##CHANGE##'};
				}
				if ($mergeCheck && defined($mergeActions->{$ssNm}->{$ssKey})) {
					$sssContent .= CheckForNewChildSubSections($mergeActions->{$ssNm}->{$ssKey},$rRef);
				}
				$sssContent = $sssStart . $allSSSParams . $sssContent . $_;
				if (defined($mergeActions->{$ssNm}->{$ssKey}->{'##CHANGE##'})) {
					$sssContent = $mergeActions->{$ssNm}->{$ssKey}->{'##CHANGE##'};
				} elsif (defined($mergeActions->{$ssNm}->{$ssKey}->{'##DELETE##'})) {
					$sssContent = '';
				}
				if ($subFiltFlg) {
					$ret = FilterSSS($href,$oNm,$mdTp,$sNm,$cfg,$ssNm,$ssKey,$sssContent);
				} else {
					$ret = $sssContent;
				}
				$ret = CheckForNewSubSections($mergeActions->{$ssNm},$ssKey,$rRef) . $ret;
				if ($ssTp eq 'SIMPLE') {
					$rptKey = "$filePath$diffSep$sNm=$sKey$diffSep$ssNm=$ssKey";
					$rRef->{$mdTp}->{$oNm}->{$fldTpNm}->{$rptKey} = $sssContent;
					DuplicateKeyCheck($href, $mdTp, $oNm, $fldTpNm, $rptKey, $sssContent);
				} else {
					$rptKey = "$filePath$diffSep$sNm=$sKey$diffSep$ssNm=$ssKey$diffSep#PARAMS#";
					$rRef->{$mdTp}->{$oNm}->{$fldTpNm}->{$rptKey} = $allSSSParams;
					$rptKey = "$filePath$diffSep$sNm=$sKey$diffSep$ssNm=$ssKey$diffSep#CONTENTS#";
					$rRef->{$mdTp}->{$oNm}->{$fldTpNm}->{$rptKey} = $sssContent;
				}
				$result .= $ret; # result contains filtered output
				$ssNm = $ssKey = $sssContent = $sssStart = $ret = $allSSSParams = '';
				$nextState = 'ProcessingSSParams';
			} elsif (/^\s*<(\w+)>[^<>]+<\/(\w+)>\s*$/) {
				$allSSSParams .= $_;
				$nextState = 'ProcessingSSS';
			} elsif (/^\s*<(\w+)>\s*$/) {
				$sssNm = $1;
				$ssssStart = $_;
				($ssKey, $ssTp) = SortSSS($mdTp,$sNm,$cfg,$ssNm,$allSSSParams . $ssssStart);
				$nextState = 'ProcessingSSSS';
			} else {
				$nextState = 'Error';
			}
		} elsif ($state eq 'ProcessingSSSS') {
			if (index($_,"</$sssNm>") >= 0) {
				if ($sssKey eq '') {
					($sssKey, $sssTp) = SortSSSS($mdTp,$sNm,$cfg,$ssNm,$sssNm,$ssssStart . $allSSSSParams);
				}
				$mergeSSSSParams = ($mergeCheck && defined($mergeActions->{$ssNm}->{$ssKey}->{$sssNm}->{$sssKey}->{'#PARAMS#'}->{'#PARAMS#'}->{'##CHANGE##'}))?1:0;
				if ($mergeSSSSParams) {
					$allSSSSParams = $mergeActions->{$ssNm}->{$ssKey}->{$sssNm}->{$sssKey}->{'#PARAMS#'}->{'#PARAMS#'}->{'##CHANGE##'};
				}
				if ($mergeCheck && defined($mergeActions->{$ssNm}->{$ssKey}->{$sssNm}->{$sssKey})) {
					$ssssContent .= CheckForNewChildSubSections($mergeActions->{$ssNm}->{$ssKey}->{$sssNm}->{$sssKey},$rRef);
				}
				$ssssContent = $ssssStart . $allSSSSParams . $ssssContent . $_;
				if (defined($mergeActions->{$ssNm}->{$ssKey}->{$sssNm}->{$sssKey}->{'##CHANGE##'})) {
					$ssssContent = $mergeActions->{$ssNm}->{$ssKey}->{$sssNm}->{$sssKey}->{'##CHANGE##'};
				} elsif (defined($mergeActions->{$ssNm}->{$ssKey}->{$sssNm}->{$sssKey}->{'##DELETE##'})) {
					$ssssContent = '';
				}
				$sssContent .= CheckForNewSubSections($mergeActions->{$ssNm}->{$ssKey}->{$sssNm},$sssKey,$rRef) . $ssssContent;
				if ($sssTp eq 'SIMPLE') {
					$rptKey = "$filePath$diffSep$sNm=$sKey$diffSep$ssNm=$ssKey$diffSep$sssNm=$sssKey";
					$rRef->{$mdTp}->{$oNm}->{$fldTpNm}->{$rptKey} = $ssssContent;
					DuplicateKeyCheck($href, $mdTp, $oNm, $fldTpNm, $rptKey, $ssssContent);
				} else {
					$rptKey = "$filePath$diffSep$sNm=$sKey$diffSep$ssNm=$ssKey$diffSep$sssNm=$sssKey$diffSep#PARAMS#";
					$rRef->{$mdTp}->{$oNm}->{$fldTpNm}->{$rptKey} = $allSSSSParams;
					$rptKey = "$filePath$diffSep$sNm=$sKey$diffSep$ssNm=$ssKey$diffSep$sssNm=$sssKey$diffSep#CONTENTS#";
					$rRef->{$mdTp}->{$oNm}->{$fldTpNm}->{$rptKey} = $ssssContent;
				}
				$sssNm = $sssKey = $ssssContent = $ssssNm = $allSSSSParams = $ssssStart = '';
				$nextState = 'ProcessingSSS';
			} elsif (/^\s*<(\w+)>[^<>]+<\/(\w+)>\s*$/) {
				$allSSSSParams .= $_;
				$nextState = 'ProcessingSSSS';
			} elsif (/^\s*<(\w+)>\s*$/) {
				$ssssNm = $1;
				$sssssContent = $_;
				($sssKey, $sssTp) = SortSSSS($mdTp,$sNm,$cfg,$ssNm,$sssNm,$allSSSSParams . $sssssContent);
				$nextState = 'ProcessingSSSSS';
			} else {
				$ssssContent .= $_;
				$nextState = 'ProcessingSSSS';
			}
		} elsif ($state eq 'ProcessingSSSSS') {
			if (index($_,"</$ssssNm>") >= 0) {
				$sssssContent .= $_;
				($ssssKey, $ssssTp) = SortSSSSS($mdTp,$sNm,$cfg,$ssNm,$sssNm,$ssssNm,$sssssContent);
				if ($mergeCheck) {
					$ssssContent .= CheckForNewSubSections($mergeActions->{$ssNm}->{$ssKey}->{$sssNm}->{$sssKey}->{$ssssNm},$ssssKey,$rRef);
					if (defined($mergeActions->{$ssNm}->{$ssKey}->{$sssNm}->{$sssKey}->{$ssssNm}->{$ssssKey}->{'##CHANGE##'})) {
						$sssssContent = $mergeActions->{$ssNm}->{$ssKey}->{$sssNm}->{$sssKey}->{$ssssNm}->{$ssssKey}->{'##CHANGE##'};
					} elsif (defined($mergeActions->{$ssNm}->{$ssKey}->{$sssNm}->{$sssKey}->{$ssssNm}->{$ssssKey}->{'##DELETE##'})) {
						$sssssContent = '';
					}
				}
				$ssssContent .= $sssssContent;
				$rptKey = "$filePath$diffSep$sNm=$sKey$diffSep$ssNm=$ssKey$diffSep$sssNm=$sssKey$diffSep$ssssNm=$ssssKey";
				$rRef->{$mdTp}->{$oNm}->{$fldTpNm}->{$rptKey} = $sssssContent;
				DuplicateKeyCheck($href, $mdTp, $oNm, $fldTpNm, $rptKey, $sssssContent);
				$ssssNm = $sssssContent = '';
				$nextState = 'ProcessingSSSS';
			} elsif (/^\s*<(\w+)>[^<>]+<\/(\w+)>\s*$/) {
				$sssssContent .= $_;
				$nextState = 'ProcessingSSSSS';
			} else {
				$sssssContent .= $_;
				$nextState = 'ProcessingSSSSS';
			}
		} elsif ($state eq 'Error') {
			$result = $content;
			last;
		} else {
			$result .= $_;
		}
		$state = $nextState;
	}
	return $result;
}

sub CheckForNewSections {
	my ($newSectNm, $mergeActions, $rptRef, $flg) = @_;
	my $sArr = [];
	foreach my $sNm (sort(keys(%$mergeActions))) {
		# if $flg = 1, then include current section name in the check
		if ($sNm lt $newSectNm || ($flg && $sNm eq $newSectNm)) {
			if (defined($mergeActions->{$sNm}->{'##CREATE##'})) {
				my $cRef = $mergeActions->{$sNm}->{'##CREATE##'};
				push(@$sArr, @$cRef);
				# Capture log
				my $msg = "Added " . scalar(@$cRef) . " item(s) in section $sNm";
				my $logArr = $rptRef->{CURRENT}->{MERGE_LOG} // [];
				push (@$logArr, $msg);
				$rptRef->{CURRENT}->{MERGE_LOG} = $logArr;
				# Release memory
				undef $mergeActions->{$sNm}->{'##CREATE##'};
			}
		} else {
			last;
		}
	}
	$sArr;
}

sub CheckForNewSubSections {
	my ($mAs,$skey,$rptRef) = @_;
	my ($ret, $item, $arrRef);
	$ret = $item = '';
	if (defined($mAs->{'##CREATE##'})) {
		$arrRef = $mAs->{'##CREATE##'};
		if (length($skey) == 32 && index($skey, ' ') < 0) {
			# Return empty string for MD5 digest keys, unless $flg = 1
			# This means that sub-sections with automatically callculated keys
			# are added as last part of parent section contents
		} else {
			while (defined($item = shift @$arrRef)) {
				last if ($item->{SORT_KEY} gt $skey);
				$ret .= $item->{CONTENT};
			}
			unshift (@$arrRef, $item) if ($item->{SORT_KEY} gt $skey);
		}
	}
	$ret;
}

sub CheckForNewChildSubSections {
	my ($mAs, $rptRef) = @_;
	my ($ret, $item, $item2, $arrRef);
	$ret = $item = '';
	foreach $item (sort(keys(%$mAs))) {
		next if (index($item,'#') == 0); # skip 'special' sections like '#PARAMS#'
		if (defined($mAs->{$item}->{'##CREATE##'})) {
			$arrRef = $mAs->{$item}->{'##CREATE##'};
			foreach $item2 (@$arrRef) {
				$ret .= $item2->{CONTENT};
			}
		}
	}
	$ret;
}

# Parse SF Metadata file into a list of ordered sections
# Input: file name and config hash reference
# Output: hash ref with results
sub ParseMetadataFile {
	my ($fn,$cRef, $rRef) = @_; # Input: metadata file name and hashRef for results
	my ($fh, $state, $nextState, $step, $nextStep, $section, $sectionName, $newSectionName, $mergeCheck);
	my ($metaDataType, $metaDataName, $lineCnt, $sectionCnt, $fldTpNm, $rptKey, $filePath, $mergeActions);
	my $hRef = {};
	$state = 'Start';
	$step = $nextStep = $nextState = $section = $metaDataType = $sectionName = $newSectionName = '';
	$lineCnt = $sectionCnt = 0;
	$hRef->{FILE_NAME} = $fn;
	$filePath = $hRef->{FILE_PATH} = $rRef->{ 'CURRENT' }->{ 'FILE_PATH' };
	$mergeActions = $rRef->{ 'CURRENT' }->{ 'MERGE_ACTIONS' } // {};
	$mergeCheck = (defined($mergeActions) && scalar(keys(%$mergeActions)) > 0)?1:0;
	$hRef->{ 'FILTERS_PRESENT' } = 0;
	if (!open($fh, "< $fn")) {
		$hRef->{RESULT} = 'NO_FILE';
		$hRef->{ERROR_MSG} = "Couldn't open $fn for reading : $!\n";
		return $hRef;
	}
	($metaDataName = basename($fn)) =~ s/\.[^.]+$//;
	while (<$fh>) {
		if ($state eq 'Start') {
			if (/^\s*<(\w+)\s+xmlns=/) {
				$metaDataType = $1;
				$hRef->{METADATA_TYPE} = $metaDataType;
				$hRef->{METADATA_NAME} = $metaDataName;
				$fldTpNm = $rRef->{ 'CURRENT' }->{ 'FLD_TP_NM' };
				$rptRef->{$metaDataType}->{$metaDataName}->{$fldTpNm} = {};
				if (defined($cfgRef->{"$metaDataType"}->{'filter'})) {
					$hRef->{ 'FILTERS_PRESENT' } = CheckFiltersPresent($cfgRef->{"$metaDataType"}->{'filter'}, $metaDataName);
				}
 				$sectionType = 'Header';
				$sectionName = $metaDataType;
				AddSection($hRef,$sectionType,$sectionName,$sectionCnt,$cRef,$rRef);
				print "Header for $metaDataType found\n" if ($debug);
				$nextState = 'ProcessingSection';
			} elsif ($lineCnt < 3) {
				$nextState = 'Start';
			} else {
				print "File $fn is not a metadata file, skipping parsing" if ($debug);
				$hRef->{RESULT} = 'NOT_METADATA_FILE';
				$hRef->{ERROR_MSG} = "File $fn is not a metadata file";
				return $hRef;
			}
		} elsif ($state eq 'ProcessingSection') {
			if (/^\s*<(\w+)>\s*$/) {
				$newSectionName = $1;
				$sectionType = 'Standard';
				if ($newSectionName ne $sectionName) {
					# Close down the last sub-section of previous section and capture sub-section content
					AddSubSection($hRef, $sectionCnt, $sectionName, $section, $cRef, $rRef);
					# Check for new sub-sections that may have to be added before this section (in case of merge)
					if ($mergeCheck) {
						$addSectionsRef = CheckForNewSections($newSectionName, $mergeActions, $rRef, 0);
						if (@$addSectionsRef > 0) {
							my $sNumber = sprintf("S%5.5d", $sectionCnt++);
							my $sRef = $hRef->{ 'SECTIONS' }->{ $sNumber }->{ 'SUB_SECTIONS' };
							push(@$sRef, @$addSectionsRef);
						}
					}
					# Open new section
					$sectionCnt++;
					$sectionName = $newSectionName;
					AddSection($hRef, $sectionType, $sectionName, $sectionCnt, $cRef, $rRef);
					$nextState = 'ProcessingSubSection';
					$section = '';
				} else {
					# Add sub section content
					AddSubSection($hRef, $sectionCnt, $sectionName, $section, $cRef, $rRef);
					$nextState = 'ProcessingSubSection';
					$section = '';
				}
			} elsif (/^\s*<(\w+)\/>\s*$/) {
				$newSectionName = $1;
				$sectionType = 'Empty';
				# Close down the last sub-section of previous section and capture sub-section content
				AddSubSection($hRef, $sectionCnt, $sectionName, $section, $cRef, $rRef);
				# Check for new sub-sections that may have to be added before this section (in case of merge)
				if ($mergeCheck) {
					$addSectionsRef = CheckForNewSections($newSectionName, $mergeActions, $rRef, 0);
					if (@$addSectionsRef > 0) {
						my $sNumber = sprintf("S%5.5d", $sectionCnt++);
						my $sRef = $hRef->{ 'SECTIONS' }->{ $sNumber }->{ 'SUB_SECTIONS' };
						push(@$sRef, @$addSectionsRef);
					}
				}
				# Log a new empty section
				$sectionCnt++;
				$section = '';
				$sectionName = $newSectionName;
				AddSection($hRef, $sectionType, $sectionName, $sectionCnt, $cRef, $rRef);
				$nextState = 'ProcessingSection';
			} elsif (/^\s*<(\w+)>[^<>]+<\/(\w+)>\s*$/) {
				$newSectionName = $1;
				$sectionType = 'Params';
				# Close down the last sub-section of previous section and capture sub-section content
				AddSubSection($hRef, $sectionCnt, $sectionName, $section, $cRef, $rRef);
				# Check for new sub-sections that may have to be added before this section (in case of merge)
				if ($mergeCheck) {
					$addSectionsRef = CheckForNewSections($newSectionName, $mergeActions, $rRef, 0);
					if (@$addSectionsRef > 0) {
						my $sNumber = sprintf("S%5.5d", $sectionCnt++);
						my $sRef = $hRef->{ 'SECTIONS' }->{ $sNumber }->{ 'SUB_SECTIONS' };
						push(@$sRef, @$addSectionsRef);
					}
				}
				# Open new section
				$sectionCnt++;
				#$sectionName = "P" . sprintf("%5.5d", $sectionCnt);
				$sectionName = $newSectionName;
				AddSection($hRef, $sectionType, $sectionName, $sectionCnt, $cRef, $rRef);
				# update report for the param line - report for level 1 params is line-by-line
				$rptKey = "$filePath$diffSep$newSectionName=#PARAM#";
				$rptRef->{$metaDataType}->{$metaDataName}->{$fldTpNm}->{$rptKey} = $_;
				#$nextState = 'ProcessingParams';
				$nextState = 'ProcessingSection';
				$section = '';
			} elsif (index($_,"</$metaDataType>") >= 0) {
				$nextState = 'End';
				# Add sub section content
				AddSubSection($hRef, $sectionCnt, $sectionName, $section, $cRef, $rRef);
				# Check for new sub-sections that may have to be added before this section (in case of merge)
				if ($mergeCheck) {
					$addSectionsRef = CheckForNewSections($sectionName, $mergeActions, $rRef, 0);
					if (@$addSectionsRef > 0) {
						my $sNumber = sprintf("S%5.5d", $sectionCnt++);
						my $sRef = $hRef->{ 'SECTIONS' }->{ $sNumber }->{ 'SUB_SECTIONS' };
						push(@$sRef, @$addSectionsRef);
					}
				}
				# Add 'End' section and sub-section
				$sectionCnt++;
				AddSection($hRef, 'End', $metaDataType, $sectionCnt, $cRef, $rRef);
				AddSubSection($hRef, $sectionCnt, $metaDataType, $_, $cRef, $rRef);
				$section = '';
			}
		} elsif ($state eq 'ProcessingSubSection') {
			if (index($_,"</$sectionName>") >= 0) {
				$nextState = 'ProcessingSection';
			} else {
				$nextState = 'ProcessingSubSection';
			}
		}
		$section .= $_;
		$state = $nextState;
		$step = $nextStep;
		$lineCnt++;
	}
	close ($fh);
	# Capture duplicate keys spotted in metadata (sanity check of input)
	CaptureDuplicateKeys($hRef,$rRef);
	return $hRef;
}

sub ReconstructMetaDataFile {
	my ($fn,$hRef,$cRef) = @_; # Input: metadata file name and hashRef for results
	my $new = $fn . '.new';
	open (NEW, ">", $new) or die "Cannot open $new: $!";
	my $sectionsRef = $hRef->{SECTIONS};
	foreach my $sectionNum (sort keys %$sectionsRef) {
		my $subSectionsRef = $hRef->{SECTIONS}->{$sectionNum}->{SUB_SECTIONS};
		my $sectionType = $hRef->{SECTIONS}->{ $sectionNum }->{SECTION_TYPE};
		my $sectionName = $hRef->{SECTIONS}->{ $sectionNum }->{SECTION_NAME};
		my $reconstructOpt = $hRef->{SECTIONS}->{ $sectionNum }->{RECONSTRUCT};
		(print "Section $sectionNum, name $sectionName, type $sectionType\n") if ($debug);
		if ($sectionType eq 'Standard') {
			if ($reconstructOpt eq '#DONOTSORT#') {
				foreach $subSection (@$subSectionsRef) {
					(print "Adding, key: " . $subSection->{SORT_KEY} . "\n") if ($debug);
					print NEW $subSection->{CONTENT};
				}
			} else {
				foreach $subSection (sort { fc($a->{SORT_KEY}) cmp fc($b->{SORT_KEY})} @$subSectionsRef) {
					(print "Adding, key: " . $subSection->{SORT_KEY} . "\n") if ($debug);
					print NEW $subSection->{CONTENT};
				}
			}

		} else {
			(print "Adding, content: " . $subSectionsRef->[0]->{CONTENT} . "\n") if ($debug);
			print NEW $subSectionsRef->[0]->{CONTENT};
		}
	}
	close(NEW);
	rename($fn, "$fn.orig") or die "Cannot rename $fn to $fn.orig: $!";
	rename($new, $fn) or die "Cannot rename $new to $fn: $!";
	unlink ("$fn.orig");
}

sub CreateReportFiles {
	my ($rptRef, $cfgRef) = @_;
	my ($csv, $rptFh, $rptFld, $stat, $hdrRef, $trgDiffFlg, $fPath, $mergeAction, $skipChildSections,
		$srcVal, $trgVal, $mdTrgRef, $diffFlg,$l1Key, $l2Key, $l3Key, $l4Key, $targetStart,
		$skipMetadata, $remMdTp, $remMdNm, $reml1Key, $reml2Key, $reml3Key);
	$rptFld = $cfgRef->{''}->{'reportFolder'} // "SfmergeReports";
	if (!-e $rptFld) {
		mkdir($rptFld) or die "Can't mkdir $rptFld: $!";
	}
	chdir $rptFld;

	# Column indicator for target 'old' values, counting from 0
	$targetStart = 13;

	# Get work team/developer name/user storis info
	my $workTeam = $cfgRef->{''}->{'workTeamName'};
	my $devlName = $cfgRef->{''}->{'developerName'};
	my $userStrs = $cfgRef->{''}->{'userStories'};

	# Get current GMT and prepare diff file name
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = gmtime(time);
	my $zuluTime = sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",
		$year+1900, $mon+1, $mday, $hour, $min, $sec);
	my $zuluTimeFN = sprintf("%04d%02d%02d_%02d%02d%02d",
		$year+1900, $mon+1, $mday, $hour, $min, $sec);
	my $diffRpt = "Diff_$zuluTimeFN.csv";
	$rptRef->{ 'CURRENT' }->{ 'DIFF_FILE_NAME' } = "$rptFld\/$diffRpt";
	my $devLogName = "$workTeam - $zuluTimeFN - $userStrs";


	# Get the header info for reports
	$csv = Text::CSV->new ({binary => 1, always_quote => 1});
	$hdrRef = $rptRef->{ 'HEADER' }->{ 'DIFFHEADER' };
	$trgDiffFlg = 0;
	$hdrLen = @$hdrRef - 1;
	if ($hdrLen >= $targetStart) {
		$trgDiffFlg = 1;
	}

	# A single diff report is prepared for all metadata recordTypes
	open $rptFh, ">:encoding(utf8)", "$diffRpt" or die "Can't create $diffRpt: $!";
	$stat = $csv->say( $rptFh, $hdrRef ); # Add the header
	# Now: read the altered header with Source and Target folder location
	$hdrRef = $rptRef->{ 'HEADER' }->{ 'DIFFHEADER2' };
	foreach my $mdTp (sort(keys(%$rptRef))) {
		next if ($mdTp eq 'CURRENT');
		next if ($mdTp eq 'HEADER');
		next if ($mdTp eq 'DUPLICATE');
		next if ($mdTp eq 'MERGE');
		next if ($mdTp eq 'DELTA');
				my $mdTpRef = $rptRef->{$mdTp};
		foreach my $mdNm (sort(keys(%$mdTpRef))) {
			my $src = @$hdrRef[$targetStart-1];
			my $mdSrcRef = $rptRef->{$mdTp}->{$mdNm}->{$src};
			my $row = [];
			$reml1Key = '';
			$skipChildSections = $skipMetadata = 0;
			foreach my $diffKey (sort(keys(%$mdSrcRef))) {
				if ($trgDiffFlg) {
					# Check for differences (ignore leading spaces)
					($srcVal = $mdSrcRef->{$diffKey}) =~ s/^\s+//gm;
					$diffFlg = 0;
					($fPath,$l1Key, $l2Key, $l3Key, $l4Key) = split "\036", $diffKey, 5;
					$l2Key //= '';
					$l3Key //= '';
					$l4Key //= '';
					# skip to the next loop iteration if processing children of a sub-section
					# that does not exit in the target
					if ($skipChildSections &&
					($l1Key eq $reml1Key ||
					($l2Key ne '' && $l2Key eq $reml2Key) ||
					($l3Key ne '' && $l3Key eq $reml3Key))
					) {
						next;
					} else {
						$skipChildSections = 0;
						$reml1Key = $reml2Key = $reml3Key = '';
					}
					foreach my $trg (@$hdrRef[$targetStart..$hdrLen]) {
						$mdTrgRef = $rptRef->{$mdTp}->{$mdNm}->{$trg};
						($trgVal = $mdTrgRef->{$diffKey} // '') =~ s/^\s+//gm;
						if ($trgVal ne $srcVal) {
							$diffFlg = 1;
							if ($l1Key eq '#OVERWRITE#' || $l1Key eq '#NEW_METADATA#') {
								if ($trgVal eq '') {
									$mergeAction = 'Create File';
									if ($l1Key eq '#NEW_METADATA#') {
										# Skip parsed metadata sections if this is a completely new
										# metadata file
										$skipMetadata = 1;
									}
								} else {
									$mergeAction = 'Update File';
								}
							} else {
								if ($trgVal eq '') {
									$mergeAction = 'Create Item';
									if ($l2Key eq '#CONTENTS#') {
										$skipChildSections = 1;
										$reml1Key = $l1Key;
									} elsif ($l3Key eq '#CONTENTS#') {
										$skipChildSections = 1;
										$reml2Key = $l2Key;
									} elsif ($l4Key eq '#CONTENTS#') {
										$skipChildSections = 1;
										$reml3Key = $l3Key;
									}
								} else {
									if ($l2Key eq '#CONTENTS#' || $l3Key eq '#CONTENTS#' || $l4Key eq '#CONTENTS#') {
										$diffFlg = 0; # do not list content of the entire sub-section, if sub-section exists in target file
									} else {
										$mergeAction = 'Update Item';
									}
								}
							}

							last;
						}
					}
					if ($diffFlg) {
						$row->[0] = "$devLogName";
						$row->[1] = "$zuluTime";
						$row->[2] = "$workTeam";
						$row->[3] = "$devlName";
						$row->[4] = "$userStrs";
						$row->[5] = "$mergeAction"; # Merge Action: TBD
						$row->[6] = "$mdTp=$mdNm";
						$row->[7] = "$fPath";
						$row->[8] = "$l1Key";
						$row->[9] = "$l2Key";
						$row->[10] = "$l3Key";
						$row->[11] = "$l4Key";
						for (my $i=$targetStart-1; $i<=$hdrLen; $i++) {
							$trg = $hdrRef->[$i];
							$mdTrgRef = $rptRef->{$mdTp}->{$mdNm}->{$trg};
							$trgVal = $mdTrgRef->{$diffKey} // '';
							$row->[$i] = $trgVal;
						}
						$stat = $csv->say( $rptFh, $row );
					}
				} else {
					$row->[$targetStart-1] = $mdSrcRef->{$diffKey};
					$stat = $csv->say( $rptFh, $row );
				}
				last if ($skipMetadata);
			}
		}
	}
	close $rptFh;
	1;
}

sub CreateDuplicateKeyReport {
	my ($rptRef, $cfgRef) = @_;
	my ($csv, $dupRef, $rptFh, $content, $cnt, $stat, $hdrRef, $row);

	# Do nothing if no duplicates found
	return if (!defined($rptRef->{'DUPLICATE'}));

	$dupRef = $rptRef->{'DUPLICATE'};

	# Get current GMT and prepare diff file name
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = gmtime(time);
	my $zuluTimeFN = sprintf("%04d%02d%02d_%02d%02d%02d",
		$year+1900, $mon+1, $mday, $hour, $min, $sec);
	my $dupRpt = "Dups\_$zuluTimeFN.csv";

	# Get the header info for reports
	$dupHdrRef = ['MetadataKey', 'Content', 'Count'];

	# A single diff report is prepared for all metadata recordTypes
	$csv = Text::CSV->new ({binary => 1, always_quote => 1});
	open $rptFh, ">:encoding(utf8)", "$dupRpt" or die "Can't create $dupRpt: $!";
	$row = [];
	$stat = $csv->say( $rptFh, $dupHdrRef ); # Add the header
	foreach my $item (sort(keys(%$dupRef))) {
		$cnt = $dupRef->{$item}->{COUNT};
		$content = $dupRef->{$item}->{VALUE};
		$item =~ s/\036/\n/g; # Display full key one element per line
		$row->[0] = $item;
		$row->[1] = $content;
		$row->[2] = $cnt;
		$stat = $csv->say( $rptFh, $row );
	}
	close $rptFh;
	1;
}
