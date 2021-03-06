function  [PRN, doppler_frequency, code_start_time, CNR] = aided_acquisition(in_sig, guessPosition, localTime, aid, prns)
%function  [doppler_frequency, code_start_time, CNR] = INITIAL_ACQUISITION(in_sig, CAcode)
%
% This function will take as input:
%
% Input               Description
% in_sig              the input signal
% CAcode              the CA code for the current satellite
%                     from GPS_SW_RCX.m
%
% The function will then conduct a rough doppler frequency search for the satellite specified over
% -FD_SIZE:FREQ_STEP:FD_SIZE (CONSTANT.m).  If a signal is found, the code will then determine
% the time delay from the beginning of in_sig to the point where the signal
% is found.
%
% The outputs are:
%
% If no satellite is found:
% Output              Description
% doppler_frequency   Will default to 0
% code_start_time     Will default to -1
% CNR                 The highest carrier-to-noise ratio found in the signal for that PRN
%
% If a satellite is found:
% Output              Description
% doppler_frequency   the rough doppler frequency in bins determined by
%                     FREQ_STEP in CONSTANT.m
% code_start_time     the absolute time delay from the beginning of in_sig
%                     to the CA Code to a precision of TP
% CNR                 the carrier-to-noise ratio of the signal found
%
% AUTHORS:  Alex Cerruti (apc20@cornell.edu), Mike Muccio (mtm15@cornell.edu)
% modified Jan. 2008 by Brady O'Hanlon (bwo1@cornell.edu)
% Copyright 2008, Cornell University, Electrical and Computer Engineering, Ithaca, NY 14850
constant;
constant_h;

DOPPLER_OFFSET = 1000;

load almanac.asc;

if(nargin<4)
    aid=0;
end

%Restrict to supplied PRNs.
if(nargin==5 && ~isempty(prns))
    index=find(ismember(almanac(:,1),prns)~=0);
    almanac=almanac(index,:);
end

%Restrict healthy satellites only.
almanac=almanac(find(almanac(:,2)==0),:);
ephema=ephem_from_almanac(almanac);

%Find local satellite elevations.
[satposa,satvela]=findsat(ephema,localTime);
elaz=elevazim(satposa,guessPosition);

%Restrict to satellites above -5 deg.
index=find(elaz(:,3)>-5);
elaz=elaz(index,:);
ephema=ephema(index,:);
satposa=satposa(index,:);
satvela=satvela(index,:);

%Calculate Doppler shift.
obsLatLong=latlong(guessPosition);
obsPos=guessPosition;
vObs=OmegaE*norm(obsPos)*cos(obsLatLong(1)*pi/180)*[-sin(obsLatLong(2)*pi/180) cos(obsLatLong(2)*pi/180) 0];
satPos=satposa(:,3:5);
satVel=satvela(:,2:4);
rho=sqrt(sum((satPos-ones(size(satPos,1),1)*obsPos).^2,2));
velpe=vObs;
rhohat=(satPos-ones(size(satPos,1),1)*obsPos)./(rho*ones(1,3));
dopp=zeros(size(satPos,1),1);
for s=1:size(satPos,1)
    dopp(s)=f_L1*((-rhohat(s,:)*(satVel(s,:)-velpe)')/(c+rhohat(s,:)*(satVel(s,:)-velpe)'))-DOPPLER_OFFSET;
end

%generate CA code for the particular satellite, and then again for each time_offset,
%and again at each time offset for each early and late CA code
%initialize arrays for speed
SV_offset_CA_code = zeros(ONE_MSEC_SAM,TP/T_RES);
E_CA_code = zeros(ONE_MSEC_SAM,TP/T_RES);
L_CA_code = zeros(ONE_MSEC_SAM,TP/T_RES);

PRN=zeros(size(ephema,1),1);
CNR=zeros(size(ephema,1),1);
doppler_frequency=zeros(size(ephema,1),1);
code_start_time=zeros(size(ephema,1),1);

for s=1:size(ephema,1)
    %and obtain the CA code for this particular satellite
    current_CA_code = sign(cacodegn(ephema(s,1))-0.5);
    %loop through all possible offsets to gen. CA_Code w/ offset
    for time_offset = 0:T_RES:TP-T_RES
        [SV_offset_CA_code(:,1 + round(time_offset/T_RES)) ...
            E_CA_code(:,1 + round(time_offset/T_RES)) ...
            L_CA_code(:,1 + round(time_offset/T_RES))] ...
            = digitize_ca(-time_offset,current_CA_code);
    end

    %Decide if the satellite is strong or weak.
    Tacc=1;
    data_start=0;
    if(elaz(s,3)>20)
        [PRN(s),doppler_frequency(s),code_start_time(s),CNR(s)]=acquire(ephema(s,1),in_sig,dopp(s),current_CA_code,Tacc,data_start);
        
        if(CNR(s)<36)
            weak=1;
        else
            weak=0;
        end
    else
        weak=1;
    end
    
    %Peform weak aiding.
    if(weak && aid)
        Tacc=10;
        data_start=0:2e-3:20e-3;
    end
    [PRN(s),doppler_frequency(s),code_start_time(s),CNR(s)]=acquire(ephema(s,1),in_sig,dopp(s),current_CA_code,Tacc,data_start);
end
return;

function [PRN, doppler_frequency, code_start_time, CNR]=acquire(prn,in_sig,dopp,CAcode,Tacc,data_start)
    constant_h;
    DOPPLER_RANGE = 300;
    
    %Keep running tally of maximum values for later use
    max_val = [0 0 0];
    
    CAcode = digitize_ca_prompt(CAcode,Tacc);

    for start=data_start
        %Bring in Tacc+1 msec of input data
        start_index=floor(ONE_MSEC_SAM*start*1e3);
        in_sig_2ms = in_sig(start_index+(1:ONE_MSEC_SAM*(Tacc+1)));

        %generate time base at 175nsec spacing
        time = [0:1:length(in_sig_2ms)-1]'.*TP;

        corr_len = 2*length(in_sig_2ms)-1;

        freqspace=dopp-DOPPLER_RANGE:FREQ_STEP:dopp+DOPPLER_RANGE;

        %initialize vectors for speed
        I2Q2 = zeros(corr_len,length(freqspace));

        %Cycle through all possible doppler shifts from -10kHz to +10kHz and run
        %xcorr at each doppler shift in the I & Q channels in order to find the
        %highest correlation peak.  The frequency bin where the highest correlation
        %peak occurs is the doppler frequency where the satellite was found, and
        %the index of the xcorrelation indicates the time offset from the beginning
        %of in_sig_3ms to where the CA code is found.
        %Step over +/- FD_SIZE in doppler shifts
        for freq_bin=1:length(freqspace)
            fd=freqspace(freq_bin);

            %frequency argument for upmodulation
            freq_argument = 2*pi*(FC-fd)*time;

            %demod at current doppler shift
            Si = in_sig_2ms.*AMP.*cos(freq_argument);

            %and get out the I and Q factors
            Sq = -in_sig_2ms.*AMP.*sin(freq_argument);

            %Do the cross correlations to get the values
            Icacorr = xcorr(Si,CAcode);
            Qcacorr = xcorr(Sq,CAcode);

            %determine index and power for this doppler frequency at which the
            %maximum signal power was detected
            I2Q2(:,freq_bin) = (Icacorr.^2 + Qcacorr.^2);
            [y,i] = max(abs(I2Q2(:,freq_bin)));
            %does the current maximum power exceed the running maximum power?
            if(max_val(2)<y)
                %if so, replace the value
                max_val = [fd, y, i];    %these are the doppler, max power, index
            end
        end
    end

    %if the CNR < CNO_MIN, set cst to invalid value
    PRN=prn;
    CNR=10*log10(((max_val(2)/(SNR_FLOOR*(Tacc)))-1)/(.001*(Tacc)));
    if(CNR<CNO_MIN)
        code_start_time = -1;
        doppler_frequency = 0;
    else
        doppler_frequency = max_val(1);

        tRewind = (FSAMP_MSEC*(Tacc))/(1+doppler_frequency/L1);
        %have to account for xcorr output length and non-zero indexing
        code_start_time = (max_val(3)-tRewind)*TP;
    end
return;