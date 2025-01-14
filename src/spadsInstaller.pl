#!/usr/bin/perl -w
#
# This program installs SPADS in current directory from remote repository.
#
# Copyright (C) 2008-2021  Yann Riou <yaribzh@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# Version 0.27 (2021/10/28)

use strict;

use Cwd;
use File::Basename 'fileparse';
use File::Copy;
use File::Path;
use File::Spec;
use FindBin;
use HTTP::Tiny;
use List::Util qw'any all none notall';

use lib $FindBin::Bin;

use SimpleLog;
use SpadsUpdater;

my $win=$^O eq 'MSWin32';
my $macOs=$^O eq 'darwin';

my $dynLibSuffix=$win?'dll':($macOs?'dylib':'so');
my $unitsyncLibName=($win?'':'lib')."unitsync.$dynLibSuffix";
my $perlUnitsyncLibName="PerlUnitSync.$dynLibSuffix";

my $spadsUrl='http://planetspads.free.fr/spads';
my @packages=(qw'getDefaultModOptions.pl help.dat helpSettings.dat springLobbyCertificates.dat SpringAutoHostInterface.pm SpringLobbyInterface.pm SimpleEvent.pm SimpleLog.pm spads.pl SpadsConf.pm spadsInstaller.pl SpadsUpdater.pm SpadsPluginApi.pm update.pl argparse.py replay_upload.py',$win?'7za.exe':'7za');
my $perlUnitsyncModule='PerlUnitSync.pm';

my $nbSteps=$macOs?14:15;
my $isInteractive=-t STDIN;
my $pathSep=$win?';':':';
my @pathes=splitPaths($ENV{PATH});
my %conf=(installDir => File::Spec->canonpath($FindBin::Bin));

if($win) {
  eval 'use Win32';
  die "\nSPADS requires Win32::API module version 0.73 or superior.\nPlease update your Perl installation (Perl 5.16.2 or superior is recommended)\n"
      unless(eval { require Win32::API; Win32::API->VERSION(0.73); 1; });
  push(@packages,$perlUnitsyncModule);
}

my $sLog=SimpleLog->new(logFiles => [''],
                        logLevels => [4],
                        useANSICodes => [-t STDOUT ? 1 : 0],
                        useTimestamps => [-t STDOUT ? 0 : 1],
                        prefix => '[SpadsInstaller] ');
sub slog {
  $sLog->log(@_);
}

my %autoInstallData;
my $autoInstallFile=File::Spec->catfile($conf{installDir},'spadsInstaller.auto');
if(-f $autoInstallFile) {
  my $fh=new FileHandle($autoInstallFile,'r');
  if(! defined $fh) {
    print "ERROR - Unable to read auto-install data from file \"$autoInstallFile\" ($!)\n";
    exit 1;
  }
  while(<$fh>) {
    next if(/^\s*(\#.*)?$/);
    if(/^\s*([^:]*[^:\s])\s*:\s*((?:.*[^\s])?)\s*$/) {
      $autoInstallData{$1}=$2;
    }else{
      s/[\cJ\cM]*$//;
      print "ERROR - Invalid line \"$_\" in auto-install file \"$autoInstallFile\"\n";
      exit 1;
    }
  }
  $fh->close();
  slog("Using auto-install data from file \"$autoInstallFile\"...",3);
}

my $genUnitsync=0;
foreach my $installArg (@ARGV) {
  if($installArg =~ /^([^=]+)=(.*)$/) {
    $conf{$1}=$2;
  }elsif($installArg eq '-g') {
    $genUnitsync=1;
  }elsif(any {$installArg eq $_} qw'stable testing unstable contrib') {
    $conf{release}=$installArg;
  }else{
    slog('Invalid usage',1);
    print "Usage:\n";
    print "  perl $0 [release]\n";
    print "  perl $0 -g\n";
    print "      release: \"stable\", \"testing\", \"unstable\" or \"contrib\"\n";
    print "      -g: (re)generate unitsync wrapper only\n";
    exit 1;
  }
}

my %prereqFound=(swig => 0, 'g++' => 0, otool => 0, install_name_tool => 0);
foreach my $prereq (keys %prereqFound) {
  $prereqFound{$prereq}=1 if(any {-f "$_/$prereq".($win?'.exe':'')} @pathes);
}
if($genUnitsync || (! $win && (! -f $perlUnitsyncModule || -f $perlUnitsyncLibName))) {
  fatalError("Couldn't find Swig, please install Swig for Perl Unitsync interface module generation") unless($prereqFound{swig});
  fatalError("Couldn't find g++, please install g++ for Perl Unitsync interface module generation") unless($prereqFound{'g++'});
  if($win) {
    fatalError('The PERL5_INCLUDE environment variable must be set to your Perl CORE include directory (for instance: "C:\\Perl\\lib\\CORE")')
        unless(exists $ENV{PERL5_INCLUDE} && -d $ENV{PERL5_INCLUDE});
    fatalError('The PERL5_LIB environment variable must be set to your Perl CORE library absolute path (for instance: "C:\\Perl\\lib\\CORE\\libperl520.a")')
        unless(exists $ENV{PERL5_LIB} && isAbsolutePath($ENV{PERL5_LIB}) && -f $ENV{PERL5_LIB});
    fatalError('The MINGDIR environment variable must be set to your MinGW install directory (for instance: "C:\\mingw")')
        unless(exists $ENV{MINGDIR} && -d "$ENV{MINGDIR}/include");
  }
}
if($macOs) {
  fatalError("Couldn't find otool, please install otool to generate Perl Unitsync interface module on macOS") unless($prereqFound{otool});
  fatalError("Couldn't find install_name_tool, please install install_name_tool to generate Perl Unitsync interface module on macOS") unless($prereqFound{install_name_tool});
}

sub fatalError { slog(shift,0); exit 1; }

sub splitPaths { return split(/$pathSep/,shift//''); }

sub isAbsolutePath {
  my $fileName=shift;
  my $fileSpecRes=File::Spec->file_name_is_absolute($fileName);
  return $fileSpecRes == 2 if($win);
  return $fileSpecRes;
}

sub isAbsoluteFilePath {
  my ($path,$fileName)=@_;
  return '' unless(isAbsolutePath($path));
  if(! -f $path) {
    $path=File::Spec->catfile($path,$fileName);
    return '' unless(-f $path);
  }
  return '' unless((File::Spec->splitpath($path))[2] eq $fileName);
  return $path;
}

sub makeAbsolutePath {
  my ($path,$defaultBaseDir)=@_;
  $defaultBaseDir//=$conf{installDir};
  $path=File::Spec->catdir($defaultBaseDir,$path) unless(isAbsolutePath($path));
  return $path;
}

sub createDir {
  my $dir=shift;
  my $nbCreatedDir=0;
  eval { $nbCreatedDir=mkpath($dir) };
  fatalError("Couldn't create directory \"$dir\" ($@)") if($@);
  slog("Directory \"$dir\" created",3) if($nbCreatedDir);
}

sub downloadFile {
  my ($url,$file)=@_;
  my $httpRes=HTTP::Tiny->new(timeout => 10)->mirror($url,$file);
  if(! $httpRes->{success} || ! -f $file) {
    slog("Unable to download $file from $url",1);
    unlink($file);
    return 0;
  }
  return 2 if($httpRes->{status} == 304);
  return 1;
}

sub escapeWin32Parameter {
  my $arg = shift;
  $arg =~ s/(\\*)"/$1$1\\"/g;
  if($arg =~ /[ \t]/) {
    $arg =~ s/(\\*)$/$1$1/;
    $arg = "\"$arg\"";
  }
  return $arg;
}

sub portableExec {
  my ($program,@params)=@_;
  my @args=($program,@params);
  @args=map {escapeWin32Parameter($_)} @args if($win);
  return exec {$program} @args;
}

sub promptStdin {
  my ($promptMsg,$defaultValue,$autoInstallValue)=@_;
  print "$promptMsg ".(defined $defaultValue ? "[$defaultValue] " : '').'? ';
  my $value;
  if(defined $autoInstallValue) {
    $value=$autoInstallValue;
    print "$value\n";
  }else{
    $value=<STDIN>;
    print "\n" unless($isInteractive);
    $value//='';
    chomp($value);
  }
  $value=$defaultValue if(defined $defaultValue && $value eq '');
  return $value;
}

sub promptChoice {
  my ($prompt,$p_choices,$default,$autoInstallValue)=@_;
  my @choices=@{$p_choices};
  my $choicesString=join(',',@choices);
  my $choice='';
  while(none {$choice eq $_} @choices) {
    $choice=promptStdin("$prompt ($choicesString)",$default,$autoInstallValue);
    $autoInstallValue=undef;
  }
  return $choice;
}

sub promptExistingFile {
  my ($prompt,$fileName,$default,$autoInstallValue)=@_;
  my $choice='';
  my $firstTry=1;
  while(! isAbsoluteFilePath($choice,$fileName)) {
    fatalError("Inconsistent data received in non-interactive mode \"$choice\", exiting!") unless($firstTry || $isInteractive);
    $firstTry=0;
    $choice=promptStdin("$prompt ($fileName)",$default,$autoInstallValue);
    $autoInstallValue=undef;
  }
  return isAbsoluteFilePath($choice,$fileName);
}

sub promptExistingDir {
  my ($prompt,$default,$acceptSpecialValue,$r_testFunction,$autoInstallValue)=@_;
  my $choice='';
  my $firstTry=1;
  while(! isAbsolutePath($choice) || ! -d $choice || index($choice,$pathSep) != -1 || (defined $r_testFunction && ! $r_testFunction->($choice))) {
    fatalError("Inconsistent data received in non-interactive mode \"$choice\", exiting!") unless($firstTry || $isInteractive);
    $firstTry=0;
    $choice=promptStdin($prompt,$default,$autoInstallValue);
    $autoInstallValue=undef;
    last if(defined $acceptSpecialValue && $choice eq $acceptSpecialValue);
  }
  return $choice;
}

sub promptDir {
  my ($prompt,$dirName,$defaultDir,$defaultBaseDir)=@_;
  my $autoInstallValue=$autoInstallData{$dirName};
  my $dir=promptStdin($prompt,$defaultDir,$autoInstallValue);
  $conf{$dirName}=$dir;
  my $fullDir=makeAbsolutePath($dir,$defaultBaseDir);
  createDir($fullDir);
  return $fullDir;
}

sub promptString {
  my ($prompt,$autoInstallValue)=@_;
  my $choice='';
  my $firstTry=1;
  while($choice eq '') {
    fatalError("Inconsistent data received in non-interactive mode \"$choice\", exiting!") unless($firstTry || $isInteractive);
    $firstTry=0;
    $choice=promptStdin($prompt,undef,$autoInstallValue);
    $autoInstallValue=undef;
  }
  return $choice;
}

sub areSamePaths {
  my ($p1,$p2)=map {File::Spec->canonpath($_)} @_;
  ($p1,$p2)=map {lc($_)} ($p1,$p2) if($win);
  return $p1 eq $p2;
}

sub setEnvVarFirstPaths {
  my ($varName,@firstPaths)=@_;
  my $needRestart=0;
  fatalError("Unable to handle path containing \"$pathSep\" character!") if(any {index($_,$pathSep) != -1} @firstPaths);
  $ENV{"SPADS_$varName"}=$ENV{$varName}//'_UNDEF_' unless(exists $ENV{"SPADS_$varName"});
  my @currentPaths=split(/$pathSep/,$ENV{$varName}//'');
  $needRestart=1 if($#currentPaths < $#firstPaths);
  if(! $needRestart) {
    for my $i (0..$#firstPaths) {
      if(! areSamePaths($currentPaths[$i],$firstPaths[$i])) {
        $needRestart=1;
        last;
      }
    }
  }
  if($needRestart) {
    my @origPaths=$ENV{"SPADS_$varName"} eq '_UNDEF_' ? () : split(/$pathSep/,$ENV{"SPADS_$varName"});
    my @newPaths;
    foreach my $path (@origPaths) {
      push(@newPaths,$path) unless(any {areSamePaths($path,$_)} @firstPaths);
    }
    $ENV{$varName}=join($pathSep,@firstPaths,@newPaths);
  }
  return $needRestart;
}

my $currentStep;
my $unitsyncDir;
sub configureUnitsyncDir {
  if(exists $conf{autoInstalledSpringDir}) {
    $conf{unitsyncDir}='';
    $unitsyncDir=$conf{autoInstalledSpringDir};
  }else{
    if(! exists $conf{unitsyncDir}) {
      my @potentialUnitsyncDirs;
      if($win) {
        @potentialUnitsyncDirs=(@pathes,File::Spec->catdir(Win32::GetFolderPath(Win32::CSIDL_PROGRAM_FILES()),'Spring'));
      }elsif($macOs) {
        @potentialUnitsyncDirs=sort {-M $a <=> -M $b} (grep {-d $_} </Applications/Spring*.app/Contents/MacOS>);
      }else{
        @potentialUnitsyncDirs=(split(/:/,$ENV{LD_LIBRARY_PATH}//''),File::Spec->catdir($ENV{HOME},'spring','lib'),'/usr/local/lib','/usr/lib','/usr/lib/spring');
      }
      my $defaultUnitsync;
      foreach my $libPath (@potentialUnitsyncDirs) {
        if(-f "$libPath/$unitsyncLibName") {
          $defaultUnitsync=File::Spec->catfile($libPath,$unitsyncLibName);
          last;
        }
      }
      my $unitsync=promptExistingFile("$currentStep/$nbSteps - Please enter the absolute path of the unitsync library".($win?', usually located in the Spring installation directory on Windows systems':''),$unitsyncLibName,$defaultUnitsync,$autoInstallData{unitsyncPath});
      $conf{unitsyncDir}=File::Spec->canonpath((fileparse($unitsync))[1]);
    }
    $currentStep++;
    $unitsyncDir=$conf{unitsyncDir};
  }

  if($win) {
    setEnvVarFirstPaths('PATH',$unitsyncDir);
  }elsif(! $macOs) {
    portableExec($^X,$0,@ARGV,map {"$_=$conf{$_}"} (keys %conf)) if(setEnvVarFirstPaths('LD_LIBRARY_PATH',$unitsyncDir));
  }
}

sub unlinkUnitsyncTmpFiles {
  map {unlink($_)} (qw'unitsync.h unitsync.cpp exportdefines.h maindefines.h PerlUnitSync.i PerlUnitSync_wrap.c PerlUnitSync_wrap.o');
}

sub unlinkUnitsyncModuleFiles {
  map {unlink($_)} ($perlUnitsyncModule,$perlUnitsyncLibName);
}

sub generatePerlUnitSync {
  slog('Generating Perl Unitsync interface module...',3);
  if(notall {downloadFile("$spadsUrl/unitsync/src/$_",$_)} (qw'unitsync.h unitsync.cpp exportdefines.h maindefines.h')) {
    unlinkUnitsyncTmpFiles();
    exit 1;
  }

  my @skippedFunctions=qw'ProcessUnitsNoChecksum GetMapInfoEx GetMapInfo GetMapDescription GetMapAuthor GetMapWidth GetMapHeight GetMapTidalStrength GetMapWindMin GetMapWindMax GetMapGravity GetMapResourceCount GetMapResourceName GetMapResourceMax GetMapResourceExtractorRadius GetMapPosCount GetMapPosX GetMapPosZ GetInfoValue GetPrimaryModName GetPrimaryModShortName GetPrimaryModVersion GetPrimaryModMutator GetPrimaryModGame GetPrimaryModShortGame GetPrimaryModDescription OpenArchiveType GetOptionStyle';
  my $exportedFunctions='';
  my $exportedFunctionsFixed='';
  my $usSrc='unitsync.cpp';
  if(-f $usSrc) {
    if(open(US_CPP,"<$usSrc")) {
      while(<US_CPP>) {
        if(/^\s*DLL_EXPORT/ || /^\s*EXPORT\(/) {
          my $functionIsSkipped=0;
          foreach my $skippedFunction (@skippedFunctions) {
            if(/[ \)]$skippedFunction[ \(]/) {
              $functionIsSkipped=1;
              last;
            }
          }
          next if($functionIsSkipped);
          if(! /;$/) {
            chomp();
            $_.=";\n";
          }
          s/[\{\}]//g;
          $exportedFunctions.=$_;
          s/^\s*EXPORT\(([^\)]*)\)/$1/;
          s/^\s*DLL_EXPORT\s*//g;
          s/\s*__stdcall//g;
          $exportedFunctionsFixed.=$_;
        }
      }
      close(US_CPP);
    }else{
      unlinkUnitsyncTmpFiles();
      fatalError("Unable to open unitsync source file ($usSrc)");
    }
  }else{
    unlinkUnitsyncTmpFiles();
    fatalError("Unable to find unitsync source file ($usSrc)");
  }

  if(open(PUS_INT,'>PerlUnitSync.i')) {
    print PUS_INT "\%module PerlUnitSync\n";
    print PUS_INT "\%{\n";
    print PUS_INT "#include \"exportdefines.h\"\n";
    print PUS_INT "#include \"maindefines.h\"\n";
    print PUS_INT "#include \"unitsync.h\"\n\n";
    print PUS_INT $exportedFunctions;
    print PUS_INT "\%}\n\n";
    print PUS_INT $exportedFunctionsFixed;
    close(PUS_INT);
  }else{
    unlinkUnitsyncTmpFiles();
    fatalError('Unable to write Perl Unitsync interface file (PerlUnitSync.i)');
  }

  system('swig -perl5 PerlUnitSync.i');
  if($?) {
    unlinkUnitsyncTmpFiles();
    unlinkUnitsyncModuleFiles();
    fatalError('Error during Unitsync wrapper source generation');
  }

  my $coreIncsString;
  if($win) {
    $coreIncsString="\"-I$ENV{MINGDIR}\\include\" \"-I$ENV{PERL5_INCLUDE}\" -m32";
  }else{
    my @coreIncs;
    foreach my $inc (@INC) {
      push(@coreIncs,"\"-I$inc/CORE\"") if(-d "$inc/CORE");
    }
    $coreIncsString=join(' ','-fpic',@coreIncs);
  }
  system("g++ -c PerlUnitSync_wrap.c $coreIncsString");
  if($?) {
    unlinkUnitsyncTmpFiles();
    unlinkUnitsyncModuleFiles();
    fatalError('Error during Unitsync wrapper compilation');
  }

  my $linkParam=$win?"\"$ENV{PERL5_LIB}\" -static-libgcc -static-libstdc++ -m32":'';
  my $dynLibFlag=$macOs?'-dynamiclib -flat_namespace -undefined suppress':'-shared';
  my $unitsyncLib=File::Spec->catfile($unitsyncDir,$unitsyncLibName);
  system("g++ $dynLibFlag PerlUnitSync_wrap.o \"$unitsyncLib\" $linkParam -o $perlUnitsyncLibName");
  unlinkUnitsyncTmpFiles();
  if($?) {
    unlinkUnitsyncModuleFiles();
    fatalError('Error during Perl Unitsync interface library compilation');
  }

  if($macOs) {
    my @unitsyncIdNameRes=`otool -D $unitsyncLib`;
    if($?) {
      unlinkUnitsyncModuleFiles();
      fatalError('Unable to retrieve Unitsync shared library ID name using "otool -D" command'.($!?" ($!)":''));
    }
    if($#unitsyncIdNameRes != 1) {
      unlinkUnitsyncModuleFiles();
      fatalError('Unexpected result when retrieving Unitsync shared library ID name');
    }
    my $unitsyncIdName=$unitsyncIdNameRes[1];
    chomp($unitsyncIdName);

    system("install_name_tool -change $unitsyncIdName $unitsyncLib $perlUnitsyncLibName");
    if($?) {
      unlinkUnitsyncModuleFiles();
      fatalError('Unable to configure Unitsync library path in Perl Unitsync interface library using "install_name_tool -change" command'.($!?" ($!)":''));
    }
  }
}

sub exportWin32EnvVar {
  my $envVar=shift;
  my $envVarDef="$envVar=".($ENV{$envVar}//'');
  fatalError("Unable to export environment variable definition \"$envVarDef\"") unless(_putenv($envVarDef) == 0);
}

sub uriEscape {
  my $uri=shift;
  $uri =~ s/([^A-Za-z0-9\-\._~])/sprintf("%%%02X", ord($1))/eg;
  return $uri;
}

sub naiveParentDir {
  my @dirs=File::Spec->splitdir(shift);
  pop(@dirs);
  return File::Spec->catdir(@dirs);
}

sub configureSpringDataDir {
  my ($baseDataDir,$mapModDataDir);
  if(exists $conf{autoInstalledSpringDir}) {
    $baseDataDir=$conf{autoInstalledSpringDir};
  }else{
    my @potentialBaseDataDirs=($unitsyncDir);
    if(! $win) {
      my $parentUnitsyncDir=naiveParentDir($unitsyncDir);
      push(@potentialBaseDataDirs,File::Spec->canonpath("$parentUnitsyncDir/share/games/spring"));
      push(@potentialBaseDataDirs,'/usr/share/games/spring') unless($macOs);
    }
    my $defaultBaseDataDir;
    foreach my $potentialBaseDataDir (@potentialBaseDataDirs) {
      if(-d "$potentialBaseDataDir/base") {
        $defaultBaseDataDir=$potentialBaseDataDir;
        last;
      }
    }
    $baseDataDir=promptExistingDir("$currentStep/$nbSteps - Please enter the absolute path of the main Spring data directory, containing Spring base content".($win?' (usually the Spring installation directory on Windows systems)':''),
                                   $defaultBaseDataDir,
                                   undef,
                                   sub {my $dir=shift; return -d "$dir/base";},
                                   $autoInstallData{baseDataDir} );
    $currentStep++;
  }

  my @potentialMapModDataDirs;
  if($win) {
    my $win32PersonalDir=Win32::GetFolderPath(Win32::CSIDL_PERSONAL());
    my $win32CommonAppDataDir=Win32::GetFolderPath(Win32::CSIDL_COMMON_APPDATA());
    push(@potentialMapModDataDirs,
         File::Spec->catdir($win32PersonalDir,'My Games','Spring'),
         File::Spec->catdir($win32PersonalDir,'Spring'),
         File::Spec->catdir($win32CommonAppDataDir,'Spring'));
  }else{
    push(@potentialMapModDataDirs,File::Spec->catdir($ENV{HOME},'.spring'),File::Spec->catdir($ENV{HOME},'.config','spring')) if(defined $ENV{HOME});
    push(@potentialMapModDataDirs,File::Spec->catdir($ENV{XDG_CONFIG_HOME},'spring')) if(defined $ENV{XDG_CONFIG_HOME});
  }
  my $defaultMapModDataDir=exists $conf{autoInstalledSpringDir}?'new':'none';
  foreach my $potentialMapModDataDir (@potentialMapModDataDirs) {
    if((! areSamePaths($potentialMapModDataDir,$baseDataDir))
       && (! -d "$potentialMapModDataDir/base")
       && (any {-d "$potentialMapModDataDir/$_"} (qw'games maps packages'))) {
      $defaultMapModDataDir=$potentialMapModDataDir;
      last;
    }
  }
  if(exists $conf{autoInstalledSpringDir}) {
    $mapModDataDir=promptExistingDir("$currentStep/$nbSteps - Please enter the absolute path of the Spring data directory containing the games and maps hosted by the autohost, or ".($defaultMapModDataDir eq 'new' ? 'press enter' : 'enter "new"').' to use a new directory instead',
                                     $defaultMapModDataDir,
                                     'new',
                                     undef,
                                     $autoInstallData{mapModDataDir});
    $currentStep++;
    if($mapModDataDir eq 'new') {
      $mapModDataDir=File::Spec->catdir($conf{absoluteVarDir},'spring','data');
      my $gamesDir=File::Spec->catdir($mapModDataDir,'games');
      my $mapsDir=File::Spec->catdir($mapModDataDir,'maps');
      slog('Retrieving the list of games available for download...',3);
      my %games=(ba => ['Balanced Annihilation','http://packages.springrts.com/builds/'],
                 bac => ['BA Chicken Defense','http://packages.springrts.com/builds/'],
                 evo => ['Evolution RTS'],
                 jauria => ['Jauria RTS'],
                 metalfactions => ['Metal Factions'],
                 nota => ['NOTA','http://host.notaspace.com/downloads/games/nota/',''],
                 phoenix => ['Phoenix Annihilation'],
                 s44 => ['Spring: 1944'],
                 swiw => ['Imperial Winter'],
                 tard => ['Robot Defense'],
                 tc => ['The Cursed'],
                 techa => ['Tech Annihilation'],
                 xta => ['XTA'],
                 zk => ['Zero-K']);
      my %gamesData;
      foreach my $shortName (sort keys %games) {
        my ($name,$repoUrl,$separator)=@{$games{$shortName}};
        $repoUrl//="http://repos.springrts.com/$shortName/builds/";
        $separator//='-';
        my $httpRes=HTTP::Tiny->new(timeout => 10)->request('GET',$repoUrl.'?C=M;O=A');
        my @gameArchives;
        @gameArchives=$httpRes->{content} =~ /href="$shortName$separator[^"]+\.sdz">($shortName$separator[^<]+\.sdz)</g if($httpRes->{success});
        if(! @gameArchives) {
          slog("Unable to retrieve archives list for game $name",2);
          next;
        }
        my $latestGameArchive=pop(@gameArchives);
        my $gameVersion;
        if($latestGameArchive =~ /^$shortName$separator\s*(.+)\.sdz$/) {
          $gameVersion=$1;
        }else{
          slog("Unable to retrieve latest archive name for game $name",2);
          next;
        }
        $gamesData{$shortName}={name => "$name $gameVersion", url => $repoUrl.uriEscape($latestGameArchive), file => $latestGameArchive};
      }
      createDir($gamesDir);
      print "\nDirectory \"$gamesDir\" has been created to store the games used by the autohost.\n";
      if(%gamesData) {
        print "You can download one of the following games in this directory automatically by entering the corresponding game abreviation, or you can choose to manually place some games archives there then enter \"none\" when finished:\n";
        my $defaultShortName;
        foreach my $shortName (sort keys %gamesData) {
          $defaultShortName//=$shortName;
          print "  $shortName : $gamesData{$shortName}{name}\n";
        }
        print "\n";
        my $downloadedShortName=promptChoice("$currentStep/$nbSteps - Which game do you want to download to initialize the autohost \"games\" directory",[(sort keys %gamesData),'none'],$defaultShortName,$autoInstallData{downloadedGameShortName});
        $currentStep++;
        if(exists $gamesData{$downloadedShortName}) {
          slog("Downloading $gamesData{$downloadedShortName}{name}...",3);
          if(downloadFile($gamesData{$downloadedShortName}{url},File::Spec->catfile($gamesDir,$gamesData{$downloadedShortName}{file}))) {
            slog("File $gamesData{$downloadedShortName}{file} downloaded.",3);
          }else{
            slog("Unable to download file \"$gamesData{$downloadedShortName}{url}\"",2);
          }
        }
      }else{
        $nbSteps--;
        print "Now you can manually place some games archives there, then press enter when finished.\n";
        <STDIN>;
        print "\n" unless($isInteractive);
      }
      createDir($mapsDir);
      print "\nDirectory \"$mapsDir\" has been created to store the maps used by the autohost.\n";
      print "You can download a minimal set of 3 maps (\"Red Comet\", \"Comet Catcher Redux\" and \"Delta Siege Dry\") in this directory automatically, or you can choose to manually place some maps archives there then enter \"no\" when finished.\n\n";
      my @mapFiles=(qw'red_comet.sd7 comet_catcher_redux.sd7 deltasiegedry.sd7');
      my $downloadMaps=promptChoice("$currentStep/$nbSteps - Do you want to download a minimal set of 3 maps to initialize the autohost \"maps\" directory",['yes','no'],'yes',$autoInstallData{downloadMaps});
      $currentStep++;
      if($downloadMaps eq 'yes') {
        slog('Downloading maps...',3);
        slog('Failed to download maps',2) unless(all {downloadFile("http://api.springfiles.com/files/maps/$_",File::Spec->catfile($mapsDir,$_))} @mapFiles);
      }
    }else{
      $nbSteps-=2;
    }
  }else{
    $mapModDataDir=promptExistingDir("$currentStep/$nbSteps - Please enter the absolute path of an optional ".($win?'':'secondary ')."Spring data directory containing additional games and maps (".($defaultMapModDataDir eq 'none' ? 'press enter' : 'enter "none"').' to skip)',
                                     $defaultMapModDataDir,
                                     'none',
                                     undef,
                                     $autoInstallData{mapModDataDir});
    $currentStep++;
  }

  my @springDataDirs=($baseDataDir);
  push(@springDataDirs,$mapModDataDir) unless($mapModDataDir eq 'none');
  if(exists $conf{autoInstalledSpringDir}) {
    $conf{springDataDir}=$mapModDataDir;
  }else{
    $conf{springDataDir}=join($pathSep,@springDataDirs);
  }

  setEnvVarFirstPaths('SPRING_DATADIR',@springDataDirs);
  $ENV{SPRING_WRITEDIR}=$conf{absoluteVarDir};
  if($win) {
    fatalError('Unable to import _putenv from msvcrt.dll ('.Win32::FormatMessage(Win32::GetLastError()).')')
        unless(Win32::API->Import('msvcrt', 'int __cdecl _putenv (char* envstring)'));
    exportWin32EnvVar('SPRING_DATADIR');
    exportWin32EnvVar('SPRING_WRITEDIR');
  }
}

sub checkUnitsync {
  my $cwd=cwd();

  slog('Checking Perl Unitsync interface module...',3);

  eval 'use PerlUnitSync';
  fatalError("Unable to load Perl Unitsync interface module ($@)") if($@);

  if(! PerlUnitSync::Init(0,0)) {
    while(my $unitSyncErr=PerlUnitSync::GetNextError()) {
      chomp($unitSyncErr);
      slog("UnitSync error: $unitSyncErr",1);
    }
    fatalError('Unable to initialize UnitSync library');
  }

  my $unitsyncVersion=PerlUnitSync::GetSpringVersion();
  slog("Unitsync library version $unitsyncVersion initialized.",3);

  my @availableMods;
  my $nbMods = PerlUnitSync::GetPrimaryModCount();
  for my $modNb (0..($nbMods-1)) {
    my $nbInfo = PerlUnitSync::GetPrimaryModInfoCount($modNb);
    my $modName='';
    for my $infoNb (0..($nbInfo-1)) {
      next if(PerlUnitSync::GetInfoKey($infoNb) ne 'name');
      $modName=PerlUnitSync::GetInfoValueString($infoNb);
      last;
    }
    if($modName eq '') {
      slog("Unable to find mod name for mod \#$modNb",1);
      next;
    }
    push(@availableMods,$modName);
  }

  PerlUnitSync::UnInit();
  chdir($cwd);
  return \@availableMods;
}

if($genUnitsync) {
  $nbSteps=3;
  if(! exists $conf{unitsyncDir}) {
      print "\nExecuting SPADS installer in Perl Unitsync interface generation mode.\n";
      print "The installer will ask you $nbSteps questions to (re)generate the Perl Unitsync interface module.\n";
      print "You can stop this process at any time by hitting Ctrl-c.\n\n";
  }

  $currentStep=1;
  configureUnitsyncDir();

  generatePerlUnitSync();

  configureSpringDataDir();

  my $r_availableMods=checkUnitsync();
  $sLog->log('No game found',2) unless(@{$r_availableMods});

  print "\nPerl Unitsync interface module (re)generated.\n";
  print "\n" unless($win);
  exit 0;
}

if(! exists $conf{release}) {
  print "\nThis program will install SPADS in the current working directory, overwriting files if needed.\n";
  print "The installer will ask you $nbSteps questions maximum to customize your installation and pre-configure SPADS.\n";
  print "You can stop this installation at any time by hitting Ctrl-c.\n";
  print "Note: if SPADS is already installed on the system, you don't need to reinstall it to run multiple autohosts. Instead, you can share SPADS binaries and use multiple configuration files and/or configuration macros.\n\n";

  $conf{release}=promptChoice("1/$nbSteps - Which SPADS release do you want to install",[qw'stable testing unstable contrib'],'testing',$autoInstallData{release});
}

my $updaterLog=SimpleLog->new(logFiles => [''],
                              logLevels => [4],
                              useANSICodes => [-t STDOUT ? 1 : 0],
                              useTimestamps => [-t STDOUT ? 0 : 1],
                              prefix => '[SpadsUpdater] ');

my $updater=SpadsUpdater->new(sLog => $updaterLog,
                              localDir => $conf{installDir},
                              repository => "$spadsUrl/repository",
                              release => $conf{release},
                              packages => \@packages);

my $updaterRc=$updater->update();
fatalError('Unable to retrieve SPADS packages') if($updaterRc < 0);
if($updaterRc > 0) {
  if($win) {
    print "\nSPADS installer has been updated, it must now be restarted as follows: \"perl $0 $conf{release}\"\n";
    exit 0;
  }
  slog('Restarting installer after update...',3);
  sleep(2);
  portableExec($^X,$0,@ARGV,$conf{release});
  fatalError('Unable to restart installer');
}
slog('SPADS components are up to date, proceeding with installation...',3);

if(! exists $conf{absoluteEtcDir}) {
  $conf{absoluteEtcDir}=promptDir("2/$nbSteps - Please choose the directory where SPADS configuration files will be stored",'etcDir','etc');
  $conf{absoluteTemplatesDir}=File::Spec->catdir($conf{absoluteEtcDir},'templates');
  createDir($conf{absoluteTemplatesDir});
}

if(! exists $conf{absoluteVarDir}) {
  $conf{absoluteVarDir}=promptDir("3/$nbSteps - Please choose the directory where SPADS dynamic data will be stored",'varDir','var');
  createDir(File::Spec->catdir($conf{absoluteVarDir},'plugins'));
  createDir(File::Spec->catdir($conf{absoluteVarDir},'spring'));
}
$updater->{springDir}=File::Spec->catdir($conf{absoluteVarDir},'spring');

if(! exists $conf{absoluteLogDir}) {
  $conf{absoluteLogDir}=promptDir("4/$nbSteps - Please choose the directory where SPADS will write the logs",'logDir','log',$conf{absoluteVarDir});
  createDir(File::Spec->catdir($conf{absoluteLogDir},'chat'));
}

if(! exists $conf{autoManagedSpringVersion}) {
  my $springBinariesType;
  if($macOs) {
    $springBinariesType='custom';
  }else{
    $springBinariesType=promptChoice("5/$nbSteps - Do you want to use official Spring binary files (auto-managed by SPADS), or a custom Spring installation already existing on the system?",[qw'official custom'],'official',$autoInstallData{springBinariesType});
  }

  if($springBinariesType eq 'official') {
    my (%springVersions,%springReleasesVersion,%springVersionsReleases);
    my @springBranches=(qw'dev release');
    my %springReleases=(stable => 'recommended release',
                        testing => 'next release candidate',
                        unstable => 'latest develop version');

    slog('Checking available Spring versions...',3);
    map { my $r_availableSpringVersions=$updater->getAvailableSpringVersions($_);
          fatalError("Couldn't check available Spring versions") unless(@{$r_availableSpringVersions});
          $springVersions{$_}=$r_availableSpringVersions; } @springBranches;
    map { my $releaseVersion=$updater->resolveSpringReleaseNameToVersion($_);
          if(defined $releaseVersion) {
            $springReleasesVersion{$_}=$releaseVersion;
            $springVersionsReleases{$releaseVersion}{$_}=1;
          } } (keys %springReleases);

    my %availableVersions=%springReleasesVersion;
    print "\nAvailable Spring versions:\n";
    foreach my $springBranch (@springBranches) {
      my $versionsToAdd=5;
      while(@{$springVersions{$springBranch}}) {
        my ($printedVersion,$versionComment)=(pop(@{$springVersions{$springBranch}}),undef);
        $availableVersions{$printedVersion}=1;
        if(exists $springVersionsReleases{$printedVersion}) {
          $versionComment=join(' + ', map { '['.uc($_)."] ($springReleases{$_})" } (sort keys %{$springVersionsReleases{$printedVersion}}));
          $versionsToAdd=5;
        }
        if($versionsToAdd >= 0) {
          if($versionsToAdd > 0) {
            print "  $printedVersion".($versionComment ? " $versionComment":'')."\n";
          }else{
            print "  [...]\n";
          }
          $versionsToAdd--;
        }
      }
    }
    print "\nPlease choose the Spring version which will be used by the autohost.\n";
    print "If you choose \"stable\", \"testing\" or \"unstable\", SPADS will stay up to date with the corresponding official Spring release by automatically downloading and using new Spring binary files when needed.\n";
    my @springVersionExamples=($springReleasesVersion{stable});
    push(@springVersionExamples,$springReleasesVersion{testing}) unless($springReleasesVersion{stable} eq $springReleasesVersion{testing});
    push(@springVersionExamples,$springReleasesVersion{unstable});
    print 'If you choose a specific Spring version number ("'.join('", "',@springVersionExamples)."\", ...), SPADS will stick to this version until you manualy change it in the configuration file.\n\n";
    my $autoManagedSpringVersion='';
    my $springVersion;
    my $autoInstallValue=$autoInstallData{autoManagedSpringVersion};
    while(! exists $availableVersions{$autoManagedSpringVersion}) {
      $autoManagedSpringVersion=promptStdin("6/$nbSteps - Which Spring version do you want to use (".(join(',',@springVersionExamples,(sort keys %springReleases),'...')).')',$springReleasesVersion{stable},$autoInstallValue);
      $autoInstallValue=undef;
      if(exists $availableVersions{$autoManagedSpringVersion}) {
        $springVersion=$springReleasesVersion{$autoManagedSpringVersion} // $autoManagedSpringVersion;
        my $springSetupRes=$updater->setupSpring($springVersion);
        if($springSetupRes < -9) {
          slog("Installation failed: unable to find, download and extract all required files for Spring $springVersion, please choose a different Spring version",2);
          $autoManagedSpringVersion='';
          next;
        }
        fatalError("Spring installation failed: internal error (you can use a custom Spring installation as a workaround if you don't know how to fix this issue)") if($springSetupRes < 0);
        slog("Spring $springVersion is already installed",3) if($springSetupRes == 0);
      }
    }
    $conf{autoManagedSpringVersion}=$autoManagedSpringVersion;
    $conf{autoInstalledSpringDir}=$updater->getSpringDir($springVersion);
  }else{
    $conf{autoManagedSpringVersion}='';
  }
}

if($macOs) {
  $currentStep=5;
}else{
  $currentStep=$conf{autoManagedSpringVersion}?7:6;
}

configureUnitsyncDir();

if(! $win) {
  if(-f $perlUnitsyncModule && -f $perlUnitsyncLibName) {
    slog('Perl Unitsync interface module already exists, skipping generation (use "-g" flag to force generation)',3);
  }else {
    generatePerlUnitSync();
  }
}

configureSpringDataDir();

my $r_availableMods=checkUnitsync();
my @availableMods=sort(@{$r_availableMods});

my $springServerType=promptChoice("$currentStep/$nbSteps - Which type of server do you want to use (\"headless\" requires much more CPU/memory and doesn't support \"ghost maps\", but it allows running AI bots and LUA scripts on server side)?",
                                  [qw'dedicated headless'],
                                  'dedicated',
                                  $autoInstallData{springServerType});
$conf{springServerType} = exists $conf{autoInstalledSpringDir} ? $springServerType : '';
$currentStep++;

if(exists $conf{autoInstalledSpringDir}) {
  $conf{springServer}='';
}else{
  my $springServerName=$win?"spring-$springServerType.exe":"spring-$springServerType";

  my @potentialSpringServerDirs=($unitsyncDir);
  if(! $win) {
    my $parentUnitsyncDir=naiveParentDir($unitsyncDir);
    push(@potentialSpringServerDirs,File::Spec->canonpath("$parentUnitsyncDir/bin"));
    push(@potentialSpringServerDirs,'/usr/games') unless($macOs);
  }
  my $defaultSpringServerPath;
  foreach my $potentialSpringServerDir (@potentialSpringServerDirs) {
    if(-f "$potentialSpringServerDir/$springServerName") {
      $defaultSpringServerPath=File::Spec->catfile($potentialSpringServerDir,$springServerName);
      last;
    }
  }

  $conf{springServer}=promptExistingFile("$currentStep/$nbSteps - Please enter the absolute path of the spring $springServerType server",$springServerName,$defaultSpringServerPath,$autoInstallData{springServer});
  $currentStep++;
}

$conf{modName}='_NO_GAME_FOUND_';
if(defined $autoInstallData{modName}) {
  $conf{modName}=$autoInstallData{modName};
  slog("Default hosted game set to \"$conf{modName}\" from auto-install data",3);
    $nbSteps-=2;
}else{
  if(! @availableMods) {
    slog("No Spring game found, consequently the \"modName\" parameter in \"hostingPresets.conf\" will NOT be auto-configured",2);
    slog('Hit Ctrl-C now if you want to abort this installation to fix the problem, or remember that you will have to set the default hosted game manually later',2);
    $nbSteps-=2;
  }else{
    my $chosenModNb='';
    if($#availableMods == 0) {
      $chosenModNb=0;
      $nbSteps--;
    }else{
      print "\nAvailable games in your \"games\" and \"packages\" folders:\n";
      foreach my $modNb (0..$#availableMods) {
        print "  $modNb --> $availableMods[$modNb]\n";
      }
      print "\n";
      while($chosenModNb !~ /^\d+$/ || $chosenModNb > $#availableMods) {
        print "$currentStep/$nbSteps - Please choose the default hosted game ? ";
        $chosenModNb=<STDIN>;
        $chosenModNb//='';
        chomp($chosenModNb);
      }
      $currentStep++;
    }
    $conf{modName}=$availableMods[$chosenModNb];

    my $modFilter;
    if($conf{modName} =~ /^(.+ )test\-\d+\-[\da-f]+$/) {
      $modFilter=quotemeta($1).'test\-\d+\-[\da-f]+';
    }else{
      $modFilter=quotemeta($conf{modName});
      $modFilter =~ s/\d+/\\d+/g;
    }

    my $isLatestMod=1;
    foreach my $availableMod (@availableMods) {
      next if($availableMod eq $conf{modName});
      if($availableMod =~ /^$modFilter$/ && $availableMod gt $conf{modName}) {
        $isLatestMod=0;
        last;
      }
    }

    if($isLatestMod) {
      my $chosenModText=$#availableMods>0?'You chose the latest version of this game currently available in your "games" and "packages" folders. ':'';
      my $useLatestMod=promptChoice("$currentStep/$nbSteps - ${chosenModText}Do you want to enable new game auto-detection to always host the latest version of the game available in your \"games\" and \"packages\" folders?",[qw'yes no'],'yes',$autoInstallData{useLatestMod});
      $currentStep++;
      if($useLatestMod eq 'yes') {
        slog("Using following regular expression as autohost default game filter: \"$modFilter\"",3);
        $modFilter='~'.$modFilter;
        $conf{modName}=$modFilter;
      }else{
        slog("Using \"$conf{modName}\" as default hosted game",3);
      }
    }else{
      $nbSteps--;
      slog("Using \"$conf{modName}\" as default hosted game",3);
    }
  }
}

$conf{lobbyLogin}=promptString("$currentStep/$nbSteps - Please enter the autohost lobby login (the lobby account must already exist)",$autoInstallData{lobbyLogin});
$currentStep++;
$conf{lobbyPassword}=promptString("$currentStep/$nbSteps - Please enter the autohost lobby password",$autoInstallData{lobbyPassword});
$currentStep++;
$conf{owner}=promptString("$currentStep/$nbSteps - Please enter the lobby login of the autohost owner",$autoInstallData{owner});
$currentStep++;

my @confFiles=qw'banLists.conf battlePresets.conf commands.conf hostingPresets.conf levels.conf mapBoxes.conf mapLists.conf spads.conf users.conf';
slog('Downloading SPADS configuration templates',3);
exit 1 unless(all {downloadFile("$spadsUrl/conf/templates/$conf{release}/$_",File::Spec->catdir($conf{etcDir},'templates',$_))} @confFiles);
slog('Customizing SPADS configuration',3);
foreach my $confFile (@confFiles) {
  my $confFileTemplate=File::Spec->catfile($conf{etcDir},'templates',$confFile);
  fatalError("Unable to read configuration template \"$confFileTemplate\"") unless(open(TEMPLATE,"<$confFileTemplate"));
  my $confFilePath=File::Spec->catfile($conf{etcDir},$confFile);
  fatalError("Unable to write configuration file \"$confFilePath\"") unless(open(CONF,">$confFilePath"));
  while(<TEMPLATE>) {
    foreach my $macroName (keys %conf) {
      s/\%$macroName\%/$conf{$macroName}/g;
    }
    print CONF $_;
  }
  close(CONF);
  close(TEMPLATE);
}

print "\nSPADS has been installed in current directory with default configuration and minimal customization.\n";
print "You can check your configuration files in \"$conf{etcDir}\" and update them if needed.\n";
print "You can then launch SPADS with \"perl spads.pl ".File::Spec->catfile($conf{etcDir},'spads.conf')."\"\n";
