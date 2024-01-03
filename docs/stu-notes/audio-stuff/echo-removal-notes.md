
matlab code: https://www.mathworks.com/help/signal/ug/echo-cancelation.html
```
    timelag = 0.23;
    delta = round(Fs*timelag);
    alpha = 0.5;

    orig = [mtlb;zeros(delta,1)];
    echo = [zeros(delta,1);mtlb]*alpha;

    mtEcho = orig + echo;

    [Rmm,lags] = xcorr(mtEcho,'unbiased');
    Rmm = Rmm(lags>0);
    lags = lags(lags>0);

    [~,dl] = findpeaks(Rmm,lags,'MinPeakHeight',0.22);
    mtNew = filter(1,[1 zeros(1,dl-1) alpha],mtEcho);
```
rust crate: https://docs.rs/basic_dsp/0.10.0/basic_dsp/

matlab xcorr: https://www.mathworks.com/help/matlab/ref/xcorr.html
in rust: https://docs.rs/basic_dsp/0.10.0/basic_dsp/trait.CrossCorrelationOps.html
    prepare_argument_padded


# other thing
- adaptive feedback cancellation - estimating the transmission between loudspeaker and microphone and suppressing the feedback signal. 
- feedback usually refers to something involving a hearing aid or earphone. 

# background noise removal
- https://github.com/jneem/nnnoiseless