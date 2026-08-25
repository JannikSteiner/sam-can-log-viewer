function build_installer()
%BUILD_INSTALLER Compile CanTraceViewer.m into a standalone .exe and package
%it as a web-delivery installer (CanTraceViewer_Setup.exe) that downloads
%the free MATLAB Runtime automatically during installation on the target
%machine. Requires MATLAB Compiler to be installed. Run from MATLAB:
%   cd CanViewer
%   build_installer
cd(fileparts(mfilename('fullpath')));

buildResults = compiler.build.standaloneApplication('CanTraceViewer.m', ...
    'ExecutableName', 'CanTraceViewer', ...
    'AdditionalFiles', {'SAM_CAN.dbc'}, ...
    'OutputDir', 'build');

opts = compiler.package.InstallerOptions(buildResults, ...
    'RuntimeDelivery', 'web', ...
    'OutputDir', 'installer', ...
    'InstallerName', 'CanTraceViewer_Setup');

compiler.package.installer(buildResults, 'Options', opts);

disp('INSTALLER_BUILD_DONE');
end
